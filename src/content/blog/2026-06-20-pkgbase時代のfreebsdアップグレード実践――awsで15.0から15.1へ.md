---
title: pkgbase時代のFreeBSDアップグレード実践――AWSで15.0から15.1へ
description: FreeBSD 15系のAWS公式AMIはpkgbase（パッケージ化されたベースシステム）でビルドされており、従来のfreebsd-updateは使えません。稼働中のEC2 arm64インスタンスを対象に、同一リリース内のパッチ適用と15.0→15.1のマイナー更新を、pkgとbectlの実コマンドで解説します。OSVERSION上書きの仕組み、15.1で分離されたPAM・zstdパッケージの落とし穴、EC2シリアルコンソールによるロールバックまで、一次資料に基づいて整理します。
pubDate: 2026-06-20T19:00:00.000+09:00
author: Yuki Tachi
tags:
  - FreeBSD
  - pkgbase
  - AWS
  - インフラ
  - アップグレード
  - ZFS
draft: true
---

## はじめに

AWS Marketplace から「FreeBSD の新しい AMI が公開されました」という通知メールが届きます。けれども、これは新規起動用イメージの更新にすぎず、稼働中のインスタンスは自分の手で更新する必要があります。

ところが FreeBSD 15 系の公式 AMI で慣れ親しんだ `freebsd-update` を叩くと、いきなり突き放されます。原因は、15 系の AMI が **pkgbase**（パッケージ化されたベースシステム）でビルドされていることにあります。本記事では、AWS EC2 上で稼働する arm64 インスタンスを対象に、同一リリース内のパッチ適用と、15.0 から 15.1 へのマイナー更新を、実際のコマンドに沿って解説します。

## 背景・課題

pkgbase とは、カーネルや基本コマンドといった「ベースシステム」を、サードパーティ製ソフトウェアと同じように `pkg` で管理する仕組みです。FreeBSD 15.0 以降で正式に利用でき、AWS の公式 AMI もこの方式でビルドされています。リリースノートも、ベースをパッケージで導入したシステム（pkgbase）に固有の注意点を別建てで記載しています（FreeBSD Project, 2026a）。

問題は、この新しいモデルが従来の `freebsd-update(8)` と相容れない点です。pkgbase のシステムで `freebsd-update fetch` を実行すると、次のエラーで停止します。

```sh
$ sudo freebsd-update fetch
freebsd-update is incompatible with the use of packaged base
```

FreeBSD Handbook も、パッケージで導入したベースの更新には `freebsd-update(8)` は適用されず、ports と同様に `pkg upgrade(8)` を使う必要があると明記しています（FreeBSD Project, 2026b）。さらに 15.1 では、ソースからの更新と取り違えないよう `installworld`／`installkernel` ターゲット自体がブロックされるようになりました（FreeBSD Project, 2026a）。つまり pkgbase では、ベースの更新も「パッケージの更新」として `pkg` に一本化されています。

## 本論

### 環境前提とブート環境の用意

前提環境は、AWS EC2 arm64（aarch64）、FreeBSD/arm64 15 (ZFS) AMI、ZFS on root です。サードパーティの kmod は使っておらず、カーネルモジュールは `zfs`・`if_ena`・`linuxulator` といった base 付属のものだけとします。この前提ならベースの更新にモジュールも追従するため、`FreeBSD-ports-kmods` リポジトリの操作は不要です。

何より先にやるべきは、ロールバック手段の確保です。ZFS on root では `bectl(8)` でブート環境（Boot Environment）を作れます。更新前の状態をまるごと退避しておけば、失敗しても切り戻せます。

```sh
# 現状を退避するブート環境を作成（ZFS なら一瞬で終わる）
sudo bectl create pre-15.1
sudo bectl list
```

なお `bectl create` は ZFS 前提です。UFS のインスタンスでは `libbe_init` が失敗するため、この手順は使えません（Aptivi, 2026）。

### 同一リリース内のパッチ適用（15.0 p系）

まず軽い方、同一リリース内のセキュリティパッチ適用です。`FreeBSD-base.conf` のリポジトリ（`base_release_0`）が有効なら、ports と同じ感覚で更新できます。現在のバージョンは `freebsd-version` で確認します。`-k` がインストール済みカーネル、`-r` が稼働中カーネル、`-u` がユーザーランドの版を表します。

```sh
freebsd-version -kru        # 例: 15.0-RELEASE-p9 15.0-RELEASE-p9 15.0-RELEASE-p9

sudo pkg update -f          # カタログを強制的に取り直す
sudo pkg upgrade -r FreeBSD-base
sudo shutdown -r now        # カーネル更新の反映には再起動が必要
```

ここでのハマりどころは二つあります。一つは、リポジトリ定義が `enabled: no` のままだと `FreeBSD-base` が見つからないこと。`pkg -vv` で有効状態を確認できます。もう一つは、カタログが古いと更新が空振りするため、`pkg update` に `-f`（強制再取得）を付ける点です。実際、公式手順から `-f` が漏れていてリポジトリが更新されなかった、という報告もあります（FreeBSD Forums, 2026）。

### 15.0 から 15.1 へのマイナー更新

本題のマイナー更新です。ここで鍵になるのが `FreeBSD-base.conf` の URL のテンプレート構造です。標準的な定義は次の形をとり、`${VERSION_MINOR}` が `pkg` によって OS の版から動的に埋め込まれます（vermaden, 2026）。

```sh
FreeBSD-base: {
  url: "pkg+https://pkg.FreeBSD.org/${ABI}/base_release_${VERSION_MINOR}",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkgbase-${VERSION_MAJOR}",
  enabled: yes
}
```

15.0 で動いている間は `${VERSION_MINOR}` が `0` なので、URL は `base_release_0`（=15.0 のパッチ）を指します。15.1 へ上げるには、`pkg` に「これから 15.1 を入れる」と教える必要があります。それが `-o OSVERSION` の上書きです。FreeBSD 15.1-RELEASE は `__FreeBSD_version` で言えば `1501000` で、これを渡すと `${VERSION_MINOR}` が `1` に解決され、リポジトリは `base_release_1` を向きます。同時に、新しい OS 版向けのパッケージを古い版へ入れるのを止める OSVERSION チェックも回避できます（pkg は本来、版が合わないパッケージの導入を拒否します。FreeBSD Project, 2026c）。

```sh
# ABI と OSVERSION を上書きして 15.1 のベースを取得（aarch64 は uname -p で得る）
sudo pkg -o ABI=FreeBSD:15:$(uname -p) -o OSVERSION=1501000 update -f -r FreeBSD-base

# 本番前に必ずドライランで差分を確認する
sudo pkg -o ABI=FreeBSD:15:$(uname -p) -o OSVERSION=1501000 upgrade -n -r FreeBSD-base

# 問題なければ実行
sudo pkg -o ABI=FreeBSD:15:$(uname -p) -o OSVERSION=1501000 upgrade -r FreeBSD-base
sudo shutdown -r now
```

アップグレード後・再起動前に `freebsd-version -kru` を見ると、ユーザーランドとインストール済みカーネルが `15.1-RELEASE`、稼働カーネルだけ `15.0-RELEASE` と表示されます。再起動すれば三つとも揃います。なお AMI の `FreeBSD-base.conf` が `base_release_0` とベタ書きされている場合は、テンプレート形（`base_release_${VERSION_MINOR}`）に直すか `base_release_1` へ書き換えてから実行してください。

### 15.1 固有の落とし穴：PAM・zstd・ssh・local-unbound

15.1 では、これまでベースに同梱されていた要素がいくつか別パッケージに分離しました。リスクが大きいのは **OpenPAM** です。リリースノートによれば、OpenPAM は新しい `FreeBSD-pam` パッケージへ移り、`FreeBSD-set-minimal`（または `-minimal-jail`）セットが入っているシステムでは自動導入されますが、そうでないシステムは `login(1)` や `sshd(8)` の認証のために自分で導入する必要があります（FreeBSD Project, 2026a）。これを入れ損ねると、再起動後に SSH ログインできなくなる恐れがあります。`zstd(1)` も同様に `FreeBSD-zstd` へ分離しました。

対策はシンプルで、再起動前のドライラン出力に両パッケージが「新規インストール」として現れるかを確認することです。

```sh
sudo pkg -o ABI=FreeBSD:15:$(uname -p) -o OSVERSION=1501000 upgrade -n -r FreeBSD-base \
  | grep -iE 'FreeBSD-(pam|zstd)'
# 表示されなければ明示的に入れておく
pkg info -l FreeBSD-pam   # 導入後、libpam が /usr/lib 配下に来ているか確認できる
```

ssh まわりも一手間あります。`FreeBSD-ssh` の更新後に設定を検証する `sshd -t` は、ホスト鍵が 600 権限のため root 権限が要ります。鍵が見当たらない場合は再生成します。

```sh
sudo sshd -t            # root でないと鍵を読めず誤検知する
sudo ssh-keygen -A      # ホスト鍵が無ければ生成
```

最後に、`local-unbound`（base 付属の DNS リゾルバ）を更新した場合は、再起動前に設定の再生成が必要です。アップグレード出力でも案内されます（Aptivi, 2026）。

```sh
sudo service local_unbound setup
sudo service local_unbound restart
```

## 実践への応用・考察

一連の手順を運用に落とすうえで、軸になるのは「壊れても戻せる」状態を常に保つことです。先に作った `pre-15.1` のブート環境があれば、再起動後に SSH へ入れなくなっても、AWS の EC2 シリアルコンソール（または EC2 Instance Connect）からローダーメニューにアクセスし、旧環境を選んで起動できます。`bectl activate -t pre-15.1` で一回限り有効化して試し、問題がなければ恒久化する二段構えが安全です。

もう一つの実務的な知見は、リポジトリ設定の使い分けです。マイナー更新のときだけ `-o OSVERSION` を一時的に上書きし、15.1 で再起動した後は `${VERSION_MINOR}` が自然に `1` を返すため、以降の 15.1 系パッチは上書きなしの `pkg update -f && pkg upgrade -r FreeBSD-base` だけで追従できます。「マイナー版更新は一時的な上書き、同一リリースのパッチは恒久設定のまま」と整理しておくと迷いません。

筆者の経験では、pkgbase の更新フロー自体は安定しているものの、ドキュメントの整備がまだ途上で、`-f` の要否や PAM 分離のような細部でつまずきがちです。vermaden 氏も「pkgbase のやり方はまだ完全には成熟していない」と述べており（vermaden, 2026）、当面はドライランと事前のブート環境を欠かさないのが堅実だと考えます。

## まとめ

- FreeBSD 15 系の AWS AMI は pkgbase 製で、`freebsd-update` は使えない。ベース更新は `pkg upgrade -r FreeBSD-base` に一本化されている。
- 同一リリース内のパッチは `pkg update -f` → `pkg upgrade -r FreeBSD-base` → 再起動で適用する。
- 15.0→15.1 は `-o OSVERSION=1501000` の上書きで `base_release_1` を参照させる。`freebsd-version -kru` で再起動要否を判断する。
- 15.1 では PAM・zstd が別パッケージに分離。ドライランで `FreeBSD-pam`／`FreeBSD-zstd` の導入を確認し、ssh・local-unbound の後処理も忘れない。
- 更新前に `bectl` でブート環境を作り、EC2 シリアルコンソールからの切り戻し経路を確保しておく。

次に pkgbase 環境を更新するときは、まず `bectl create` で退避し、`upgrade -n` のドライランを一度眺めてから本番に進んでください。この二つを習慣にするだけで、リモートのインスタンスでも安心してメジャー更新に踏み込めます。

## 参考文献

### 公式ドキュメント

- FreeBSD Project. (2026a). *FreeBSD 15.1-RELEASE Release Notes*. 2026年6月閲覧. https://www.freebsd.org/releases/15.1R/relnotes/
- FreeBSD Project. (2026b). *FreeBSD Handbook, Chapter 26: Updating and Upgrading FreeBSD*. 2026年6月閲覧. https://docs.freebsd.org/en/books/handbook/cutting-edge/
- FreeBSD Project. (2026c). *pkg: The osversion check should default to NO (Issue #1839)*. GitHub. 2026年6月閲覧. https://github.com/freebsd/pkg/issues/1839

### Web記事

- Aptivi. (2026). *Upgrading FreeBSD PKGBASE system from FreeBSD v15.0 to v15.1*. 2026年6月閲覧. https://officialaptivi.wordpress.com/2026/06/16/upgrading-freebsd-pkgbase-system-from-freebsd-v15-0-to-v15-1/
- FreeBSD Forums. (2026). *Updating 15.0-RELEASE-p9 to 15.1-RELEASE with PKGBASE*. 2026年6月閲覧. https://forums.freebsd.org/threads/updating-15-0-release-p9-to-15-1-release-with-pkgbase-idw.103023/
- Khera, V. (2025). *Upgrading FreeBSD 14 to 15 with pkgbase*. 2026年6月閲覧. https://vivek.khera.org/posts/2025-12-03-upgrading-freebsd-14-to-15-with-pkgbase/
- vermaden. (2026). *FreeBSD PKGBASE Minor Upgrades*. 2026年6月閲覧. https://vermaden.wordpress.com/2026/05/10/freebsd-pkgbase-minor-upgrades/
