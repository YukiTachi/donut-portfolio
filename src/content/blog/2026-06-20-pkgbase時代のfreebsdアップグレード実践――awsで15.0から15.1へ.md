---
title: pkgbase時代のFreeBSDアップグレード実践――AWSで15.0から15.1へ
description: freebsd-updateが使えないpkgbase環境のAWS
  EC2インスタンスで、同一リリース内のパッチ適用と15.0→15.1のマイナー更新を、実際に通したコマンドに沿って解説する。
pubDate: 2026-06-20T19:00:00.000+09:00
author: Yuki Tachi
tags:
  - FreeBSD
  - pkgbase
  - AWS
  - インフラ
  - アップグレード
  - ZFS
draft: false
---

## はじめに
 
AWS Marketplace から「FreeBSD の新しい AMI が公開されました」という通知メールが届きます。けれども、これは新規起動用イメージの更新にすぎず、稼働中のインスタンスは自分の手で更新する必要があります。
 
ところが FreeBSD 15 系の公式 AMI で慣れ親しんだ `freebsd-update` を叩くと、いきなり突き放されます。原因は、15 系の AMI が **pkgbase**（パッケージ化されたベースシステム）でビルドされていることにあります。本記事では、AWS EC2 上で稼働する arm64 インスタンスを対象に、同一リリース内のパッチ適用と、15.0 から 15.1 へのマイナー更新を、実際に筆者が通したコマンドに沿って解説します。
 
なお本記事の手順は、筆者が実機（後述の前提環境）で実際に実行し、成功を確認したものです。同じ目的を達成する別の方法も存在しますが、ここでは実際に検証した経路を中心に記します。
 
## 背景・課題
 
pkgbase とは、カーネルや基本コマンドといった「ベースシステム」を、サードパーティ製ソフトウェアと同じように `pkg` で管理する仕組みです。FreeBSD 15.0 以降で利用でき、AWS の公式 AMI もこの方式でビルドされています。FreeBSD 15.0 のリリースアナウンスも、パッケージ方式で導入したシステムは pkg(8) だけで管理され、クラウド向けの公開イメージはすべてこの方式が既定だと述べています（FreeBSD Project, 2025）。
 
問題は、この新しいモデルが従来の `freebsd-update(8)` と相容れない点です。pkgbase のシステムで `freebsd-update fetch` を実行すると、次のエラーで停止します。
 
```sh
$ sudo freebsd-update fetch
freebsd-update is incompatible with the use of packaged base
```
 
FreeBSD Handbook も、パッケージで導入したベースの更新には ports と同様に `pkg` を使うと整理しています（FreeBSD Project, 2026b）。つまり pkgbase では、ベースの更新も「パッケージの更新」として `pkg` に一本化されています。
 
## 本論
 
### 環境前提とブート環境の用意
 
前提環境は次のとおりです。
 
- AWS EC2 arm64（aarch64）
- FreeBSD/arm64 15 (ZFS) AMI、ZFS on root
- サードパーティの kmod は不使用。ロード済みカーネルモジュールは `zfs`・`if_ena`（AWS ENA）・`linuxulator` 系といった base 付属のものだけ
この前提ならベースの更新にモジュールも追従するため、`FreeBSD-ports-kmods` リポジトリの個別操作は不要です。逆に `drm-kmod` や `acpi_call` などをパッケージで入れている場合は、後述の一時リポジトリ設定を使って `FreeBSD-ports-kmods` も更新する必要があります（FreeBSD Forums, 2026a）。
 
何より先にやるべきは、ロールバック手段の確保です。ZFS on root では `bectl(8)` でブート環境（Boot Environment）を作れます。更新前の状態をまるごと退避しておけば、失敗しても切り戻せます。
 
```sh
# 現状を退避するブート環境を作成（ZFS なら一瞬で終わる）
sudo bectl create pre-15.1
bectl list
```
 
加えて、SSH でしか入れない EC2 インスタンスでこの作業をするなら、**EC2 シリアルコンソール（または EC2 Instance Connect）が使える状態か**を事前に確認しておきます。後述の PAM 分離でログイン不能になった場合の、唯一の復旧経路になります。
 
### 同一リリース内のパッチ適用（15.0 p系）
 
まず軽い方、同一リリース内のセキュリティパッチ適用です。`FreeBSD-base` リポジトリ（`base_release_0`）が有効なら、ports と同じ感覚で更新できます。現在のバージョンは `freebsd-version` で確認します。`-k` がインストール済みカーネル、`-r` が稼働中カーネル、`-u` がユーザーランドの版を表します。
 
```sh
freebsd-version -kru        # 例: 15.0-RELEASE-p1 ×3
 
sudo pkg update             # カタログ取得
sudo pkg upgrade            # FreeBSD-base から多数のパッケージが更新される
sudo shutdown -r now        # カーネル更新の反映には再起動が必要
 
# 再起動後
freebsd-version -kru        # 3つとも 15.0-RELEASE-p10 になれば完了
```
 
ここでのハマりどころが二つあります。一つは、リポジトリ定義が `enabled: no` のままだと `FreeBSD-base` が更新元として効かないこと。AWS の AMI でもこの状態のことがあり、その場合は `/usr/local/etc/pkg/repos/FreeBSD-base.conf` に有効化のオーバーライドを置きます。
 
```sh
sudo mkdir -p /usr/local/etc/pkg/repos
echo 'FreeBSD-base: { enabled: yes }' | \
  sudo tee /usr/local/etc/pkg/repos/FreeBSD-base.conf
sudo pkg update
```
 
これは 15.0 のリリースノートでも案内されている、一行で有効化する正規の方法です（FreeBSD Project, 2025）。
 
もう一つは、`pkg rquery` でリポジトリ側のバージョンを確認するとき、pkg 2.x 系では引数なしの全件出力に `-a` が必要な点です。これを知らないと「カタログが空に見える」と誤認します。特定パッケージを名指しすれば `-a` なしでも引けます。
 
```sh
# これは（pkg 2.x では）何も返さない
pkg rquery '%n %v' -r FreeBSD-base
# 名指しなら引ける
pkg rquery '%n %v' -r FreeBSD-base FreeBSD-kernel-generic
```
 
### 15.0 から 15.1 へのマイナー更新
 
本題のマイナー更新です。ここはパッチ適用より一段リスクが高いので、**一時的なリポジトリ設定**を使う方法を採ります。恒久設定（`FreeBSD-base.conf`）を先に書き換えると失敗時に戻しにくいため、更新の間だけ別ディレクトリの設定を読ませる、というのが要点です。この手順は FreeBSD 公式フォーラムの pkgbase 利用スレッドで案内されているものと同じです（FreeBSD Forums, 2026a）。
 
15.0 のリポジトリは `base_release_0`（15.0 のパッチ系列）を指しています。15.1 へ上げるには、`base_release_1` を指す一時設定を用意し、OS バージョン番号のミスマッチを無視させる `IGNORE_OSVERSION=yes` を付けて `pkg` を実行します（15.0→15.1 で `__FreeBSD_version` が `1500xxx` から `1501xxx` に変わるため、これを付けないと pkg がバージョン不一致を理由に拒否します）。
 
```sh
# 1. ロールバック地点（必須）
sudo bectl create pre-15.1
 
# 2. 一時リポジトリ設定を作成
sudo mkdir -p /tmp/upgrade-15.1
echo 'FreeBSD-base: { url: "pkg+https://pkg.FreeBSD.org/${ABI}/base_release_1" }' | \
  sudo tee /tmp/upgrade-15.1/upgrade.conf
 
# 3. まずドライランで差分を確認する
sudo pkg -o REPOS_DIR="/etc/pkg,/usr/local/etc/pkg/repos,/tmp/upgrade-15.1" \
  -o IGNORE_OSVERSION=yes upgrade -n -r FreeBSD-base
 
# 4. 問題なければ本実行
sudo pkg -o REPOS_DIR="/etc/pkg,/usr/local/etc/pkg/repos,/tmp/upgrade-15.1" \
  -o IGNORE_OSVERSION=yes upgrade -r FreeBSD-base
```
 
ドライラン（手順3）では、カタログ切り替えに伴って `wrong packagesite, need to re-create database` というメッセージが出ますが、これはリポジトリ URL が変わったときの正常な再作成で、その後カタログを取り直せば問題ありません。出力の中に `FreeBSD-kernel-generic` が `15.0p10 -> 15.1` へ上がること、後述の `FreeBSD-pam` が新規インストールに含まれることを必ず確認してから本実行に進みます。
 
本実行が終わったら、**再起動の前に**次節のチェックを行います。`shutdown -r now` はそのチェックを通してからです。再起動後、ログインできたら確認します。
 
```sh
freebsd-version -kru   # 3つとも 15.1-RELEASE
uname -aKU             # OSVERSION が 1501xxx 系になっているか
zpool status           # ZFS プールが正常か
```
 
なお、AMI の `FreeBSD-base.conf` が `base_release_0` とベタ書きされている場合、ここまでの手順は一時設定で上書きしているのでそのまま通ります。恒久設定の更新は、無事に 15.1 で再起動できたあと（最終節）に行います。
 
### 15.1 固有の落とし穴：PAM・zstd・ssh・local-unbound
 
15.1 では、これまでベースに同梱されていた要素がいくつか別パッケージに分離しました。リスクが大きいのは **OpenPAM** です。リリースノートによれば、OpenPAM は新しい `FreeBSD-pam` パッケージへ移り、`FreeBSD-set-minimal`（または `FreeBSD-set-minimal-jail`）セットが入っているシステムでは自動導入され、ユーザー操作は不要とされています（FreeBSD Project, 2026a）。裏を返すと、これらのセットが入っていないシステムは `login(1)` や `sshd(8)` の認証のために自分で導入する必要があり、入れ損ねると**再起動後に SSH ログインできなくなります**。実際にこの状態に陥った報告がフォーラムに複数あります（FreeBSD Forums, 2026b）。`zstd(1)` も同様に `FreeBSD-zstd` へ分離しました。
 
対策はシンプルで、再起動前のドライラン出力に両パッケージが「新規インストール」として現れるかを確認することです。
 
```sh
# ドライラン出力に FreeBSD-pam / FreeBSD-zstd が New INSTALLED で出るか
sudo pkg -o REPOS_DIR="/etc/pkg,/usr/local/etc/pkg/repos,/tmp/upgrade-15.1" \
  -o IGNORE_OSVERSION=yes upgrade -n -r FreeBSD-base | grep -iE 'FreeBSD-(pam|zstd)'
 
# 本実行後、実際に入ったか確認
pkg info -x pam        # FreeBSD-pam, FreeBSD-pam-lib などが並べば OK
```
 
PAM は `FreeBSD-pam-lib`（`libpam`。認証する側のアプリが使う共有ライブラリ）と `FreeBSD-pam`（`pam_unix.so` などの PAM モジュール本体）に分かれます。15.1 では `libpam` の実体は `/usr/lib/` 配下に置かれます（従来の `/lib/` ではありません）。確認するなら次のとおりです。
 
```sh
ls -la /usr/lib/libpam.so*   # libpam.so -> libpam.so.6 などが見える
ls -la /etc/pam.d/           # sshd, login, system があるか
```
 
ssh まわりも一手間あります。`FreeBSD-ssh` の更新後に設定を検証する `sshd -t` を **sudo なしで実行すると、ホスト鍵（600 権限）を読めず「No host key files found」と誤検知**します。これは設定エラーではないことが多く、sudo を付けて再確認すれば通ります。本当に鍵が無いときだけ再生成します。
 
```sh
sudo sshd -t                 # sudo なしだと鍵を読めず誤検知する
ls -la /etc/ssh/ssh_host_*   # 鍵が存在するか
sudo ssh-keygen -A           # 本当に鍵が無ければ生成（鍵が変わると known_hosts 更新が要る）
```
 
筆者の環境では鍵は既存のまま残っており、`sudo sshd -t` は問題なく通りました。ホスト鍵が変わらなければ、再接続時のフィンガープリント警告も出ません。
 
最後に、`local-unbound`（base 付属の DNS リゾルバ）を更新した場合は、再起動前に設定の再生成が必要です。アップグレード出力にも案内が表示されます。
 
```sh
sudo service local_unbound setup
```
 
DNS リゾルバとして使っていなければスキップして構いません。
 
## 実践への応用・考察
 
一連の手順を運用に落とすうえで、軸になるのは「壊れても戻せる」状態を常に保つことです。先に作った `pre-15.1` のブート環境があれば、再起動後に SSH へ入れなくなっても、AWS の EC2 シリアルコンソールからローダーメニューにアクセスし、旧環境を選んで起動できます。`bectl activate -t pre-15.1` で一回限り有効化して試し、問題がなければ恒久化する二段構えが安全です。
 
無事に 15.1 で安定動作したら、最後に恒久リポジトリ設定を更新します。今後の 15.1 系セキュリティパッチを通常運用で追従できるようにするためです。
 
```sh
# 恒久設定を base_release_1 に更新
sudo tee /usr/local/etc/pkg/repos/FreeBSD-base.conf << 'EOF'
FreeBSD-base: {
  url: "pkg+https://pkg.FreeBSD.org/${ABI}/base_release_1",
  enabled: yes
}
EOF
 
sudo pkg update
sudo rm -rf /tmp/upgrade-15.1   # 一時設定を削除
```
 
ここで整理しておくと、リポジトリ設定の使い分けはこうなります。**マイナー版の更新のときだけ一時リポジトリ設定（`base_release_1`）と `IGNORE_OSVERSION=yes` を使い、更新後は恒久設定を新しい系列に書き換える。同一リリース内のパッチは、恒久設定のまま `pkg upgrade` → 再起動だけで追従する。** こう決めておくと迷いません。次の 15.2 が出たときも、`base_release_2` を指す一時設定で同じ流れを踏めばよいことになります。
 
筆者の経験では、pkgbase の更新フロー自体は安定しているものの、ドキュメントの整備がまだ途上で、リポジトリの有効化や PAM 分離のような細部でつまずきがちです。当面はドライランと事前のブート環境を欠かさないのが堅実だと考えます。
 
## まとめ
 
- FreeBSD 15 系の AWS AMI は pkgbase 製で、`freebsd-update` は使えない。ベース更新は `pkg` に一本化されている。
- 同一リリース内のパッチは、リポジトリを有効化したうえで `pkg update` → `pkg upgrade` → 再起動で適用する。`pkg rquery` の全件表示には `-a` が要る点に注意。
- 15.0→15.1 は、`base_release_1` を指す一時リポジトリ設定と `IGNORE_OSVERSION=yes` を使って `pkg upgrade -r FreeBSD-base` を実行する。更新後に恒久設定を書き換える。
- 15.1 では PAM・zstd が別パッケージに分離。ドライランで `FreeBSD-pam`／`FreeBSD-zstd` の新規インストールを確認し、ssh の `sudo sshd -t`・`local-unbound` の後処理も忘れない。
- 更新前に `bectl` でブート環境を作り、EC2 シリアルコンソールからの切り戻し経路を確保しておく。
次に pkgbase 環境を更新するときは、まず `bectl create` で退避し、`upgrade -n` のドライランを一度眺めてから本番に進んでください。この二つを習慣にするだけで、リモートのインスタンスでも安心してマイナー更新に踏み込めます。
 
## 参考文献
 
### 公式ドキュメント
 
- FreeBSD Project. (2026a). *FreeBSD 15.1-RELEASE Release Notes*. 2026年6月閲覧. https://www.freebsd.org/releases/15.1R/relnotes/
- FreeBSD Project. (2026b). *FreeBSD Handbook, Chapter 26: Updating and Upgrading FreeBSD*. 2026年6月閲覧. https://docs.freebsd.org/en/books/handbook/cutting-edge/
- FreeBSD Project. (2025). *FreeBSD 15.0-RELEASE Announcement* および *Release Notes*. 2026年6月閲覧. https://www.freebsd.org/releases/15.0R/announce/
### Web記事・フォーラム
 
- FreeBSD Forums. (2026a). *FreeBSD 15 pkgbase usage*. 2026年6月閲覧. https://forums.freebsd.org/threads/freebsd-15-pkgbase-usage.102788/
- FreeBSD Forums. (2026b). *Pkgbase 15 to 15.1 stories?*. 2026年6月閲覧. https://forums.freebsd.org/threads/pkgbase-15-to-15-1-stories.103012/
