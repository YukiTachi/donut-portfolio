---
title: Cursor Dev Containerの接続エラーを解く――トークン不一致ループとBusyBox flockの罠
description: CursorのDev
  Container接続が「確立できない・すぐ切れる」とき、原因はホスト・WSL2・コンテナOS・compose構成のどこにでもあり得ます。WSL2+Docker
  Desktop環境で筆者が実際に踏んだ2つの罠――cursor-serverのトークン不一致ループ(WSL2のメモリ逼迫が再誘発)と、AlpineコンテナのBusyBox版flockによる接続不能――を軸に、レイヤーごとの切り分けと解決手順を解説します。
pubDate: 2026-07-05T19:00:00.000+09:00
author: Yuki Tachi
tags:
  - Cursor
  - Dev Container
  - WSL2
  - Docker
  - Alpine
  - トラブルシューティング
draft: false
---

## はじめに

Cursor の Dev Container 機能を使うと、エディタの UI はホストに置いたまま、開発環境をコンテナに閉じ込められます。便利な仕組みですが、「Connecting… のまま進まない」「接続できてもすぐ切れて再試行が始まる」という症状に出会いがちです。厄介なのは、原因がホスト側の Cursor、WSL2 のリソース、コンテナの OS 構成、Docker Compose の設定と多層にまたがり、画面に出る情報だけではどの層が悪いのか判別しにくい点です。

本記事では、筆者が NutriSearch の開発環境で実際に踏んだ 2 つの罠――cursor-server のトークン不一致ループと、Alpine コンテナの BusyBox 版 `flock` による接続不能――を題材に、原因の切り分け方と解決手順を記します。

## 背景・課題

前提となる筆者の環境は次のとおりです。

- Windows 上の WSL2 + Docker Desktop
- 7 つのコンテナが 1 つの WSL2 VM(メモリ 7.5GB)を共有
- 対象コンテナは `nutrition-app`(Next.js)と `nutrisearch-mcp`(Alpine 3.23 ベースの MCP サーバ)

Dev Container 仕様は、開発コンテナをユーザーがアプリケーションを開発するためのコンテナとして定義し、準備が整った後にツールがそこへ接続するモデルを示しています(Development Containers, 2026)。Cursor は VS Code 系のリモート開発モデルを継承しており、バージョン 0.22.0(2024 年 1 月)で Dev Container 対応を発表しました(Cursor, 2024)。接続時にはコンテナ内に cursor-server 系のプロセス群が展開され、ホストの Cursor はこのサーバに接続して編集・ターミナル・拡張機能を動かします。

つまり接続エラーは「ホストの Cursor ↔ コンテナ内 cursor-server ↔ コンテナの実行環境」という経路のどこかで起きています。エラーメッセージは最外層の症状しか教えてくれないことが多く、層を意識した切り分けが必要になります。

## 本論

### 罠①: 再接続ループ(cursor-server のトークン不一致の疑い)

最初の罠は `nutrition-app`(Next.js)コンテナで起きました。症状は、接続が確立できないまま再試行を繰り返す、あるいはいったん接続できても切断されて再接続ループに入る、というものです。コンテナ自体は正常で、`docker exec` で入れば中のプロセスも生きています。観測した事実と推定を分けると次のとおりです。

- **観測した事実**: WSL2 VM のメモリが逼迫したタイミングで cursor-server 系プロセスが落ち、以後の再接続が失敗し続けた。cursor-server のデータディレクトリを消して接続し直すと復旧した。
- **推定**: コンテナ内の cursor-server が保持する接続トークンとホスト側の期待がずれると再接続が成立しない。メモリ逼迫による強制終了(OOM kill)後の不完全な再起動が、このずれを再誘発していた。

背景にあるのは WSL2 のメモリ既定値です。WSL2 VM に割り当てられるメモリの既定値は、Microsoft の公式ドキュメントではホストの全メモリの 50% と説明されています(Microsoft, 2026a)。筆者の環境ではこの割り当てが 7.5GB で、そこに 7 コンテナ(Next.js のビルドプロセスを含む)が同居していたため、恒常的に逼迫しやすい状態でした。切り分けは次の手順です。

```sh
# コンテナ内: cursor-server 系プロセスの生存確認
docker exec -it nutrition-app ps aux | grep -i cursor

# WSL2 側: メモリの逼迫と OOM の痕跡を確認
free -h
dmesg | grep -i -E 'oom|killed process'
```

OOM の痕跡があれば、`%UserProfile%\.wslconfig` で VM 全体の上限を明示します(反映には WSL の再起動が必要です)。

```ini
[wsl2]
memory=12GB
```

そのうえで、メモリを食いやすいコンテナには compose 側で上限を付け、cursor-server のデータディレクトリを削除してから接続し直します。

```yaml
# compose 側でコンテナごとにメモリ上限を設定する例
services:
  nutrition-app:
    mem_limit: 2g   # Compose v2 では deploy.resources.limits.memory も利用可
```

```sh
# コンテナ内の cursor-server ディレクトリをクリアして再接続
docker exec -it nutrition-app rm -rf /root/.cursor-server
```

筆者の環境では、メモリ上限の調整とディレクトリのクリアで再接続ループは収まりました。トークン不一致という内部機構は Cursor の公開ドキュメントに記述がないため推定にとどまりますが、「メモリ逼迫 → サーバプロセスの異常終了 → 再接続不能」という連鎖自体は再現性のある観測でした。

### 罠②: Alpine コンテナと BusyBox 版 flock

2 つ目の罠は `nutrisearch-mcp`(Alpine 3.23)で起きました。同じ操作で `nutrition-app` には入れるのに、このコンテナだけ Dev Container 接続が確立できません。`docker exec` では問題なく入れます。

原因は Alpine のユーザーランドにありました。Alpine の基本コマンド群は BusyBox で提供されており、その `flock`(ファイルロックを取るユーティリティ)は本家 util-linux 版のサブセットです。BusyBox のソースコードでは、サポートされるオプションは `-s`/`-x`/`-n`/`-u`(と `-c`)のみで、util-linux 版にあるタイムアウト指定 `-w`(`--wait`/`--timeout`)などは実装されていません(BusyBox Project, 2026; util-linux, 2026)。

筆者の環境では、util-linux を導入した途端に接続できるようになりました。

```sh
# Alpine コンテナ内で util-linux 版 flock を導入する
apk add util-linux
```

このことから、cursor-server の起動処理が BusyBox 版にない `flock` の機能に依存していると筆者は推定しています(本記事執筆時点の挙動です。Cursor 側の実装変更で変わる可能性があります)。

なお、Alpine を開発コンテナにすること自体に注意が要ります。VS Code の公式ドキュメントは Alpine(musl)を Dev Containers と WSL でのみサポートすると説明し、glibc 依存のネイティブコードを含む拡張機能は動かないことがあると明記しています(Microsoft, 2026b)。Cursor も Alpine 対応をベータと位置づけ、フォーラムの案内では v0.50.5 以降とコンテナ側の `bash`・`libstdc++`・`wget`・`openssh` が必要とされています(ただし `openssh` は SSH 接続向けで、Dev Container 経由の場合は不要です)(Cursor Forum, 2025)。Alpine で入れないときは、`flock` を含む「BusyBox と util-linux の差異」をまず疑うのが近道です。

### 付随する罠: 起動順序と external ネットワーク

Dev Container の問題と混同しやすいのが、compose の外部ネットワーク起因のエラーです。筆者の構成では `nutrisearch-mcp` が WinterCMS 側の compose の作るネットワークを参照します。

```yaml
networks:
  wintercms_wintercms-network:
    external: true
```

Docker の公式リファレンスは `external: true` のネットワークについて、Compose は作成を試みず、存在しなければエラーを返すと明記しています(Docker Inc., 2026)。つまり WinterCMS 側を先に起動していないと、`nutrisearch-mcp` はコンテナの起動自体に失敗します。Dev Container 層より手前の失敗ですが、「Cursor から入れない」という見え方は同じなので、切り分けの最初に `docker compose ps` でコンテナの起動を確認する価値があります。

## 実践への応用・考察

今回の 2 つの罠から一般化できるのは、「接続エラーを層で捉える」という切り分けの型です。

1. **compose 構成の層**: そもそもコンテナは起動しているか(`docker compose ps`、external ネットワークの有無)
2. **コンテナ OS の層**: ユーザーランドは要件を満たすか(Alpine なら BusyBox の制約、`bash`・`libstdc++` の有無)
3. **WSL2 リソースの層**: メモリは足りているか(`free`、`dmesg` の OOM 痕跡、`.wslconfig`)
4. **ホスト Cursor ↔ cursor-server の層**: サーバプロセスの生存とデータディレクトリの健全性

切り分けの実用的な目印として、`docker exec` では入れるのに Dev Container では入れない、という違いが効きます。これはコンテナの起動や OS 要件ではなく、ホスト Cursor ↔ cursor-server の層に問題があることを示します。なお本記事で罠を紹介した順序(遭遇順＝上位層から)と、ここで勧める切り分け順(下位層から)はあえて逆にしています。

筆者の経験では、エラーダイアログの文言から直接原因に辿り着けることは少なく、下の層(1)から順に潰すほうが結果的に速いと感じます。特に WSL2 のメモリ既定値と Alpine のユーザーランド差異は、どちらも「普段は見えない前提」であるため盲点になりやすい箇所です。複数コンテナを 1 つの WSL2 VM に同居させるなら、Dev Container を使う・使わないにかかわらず `.wslconfig` での明示的なメモリ設計が堅実です。

## まとめ

- Cursor の Dev Container 接続エラーは「compose 構成 / コンテナ OS / WSL2 リソース / ホスト↔cursor-server」の多層で起きる。下の層から順に切り分ける。
- 再接続ループは WSL2 のメモリ逼迫による cursor-server の異常終了が引き金になり得る。`.wslconfig` の `memory=` とコンテナのメモリ上限で予防し、復旧は cursor-server ディレクトリのクリアと再接続で行う。
- Alpine コンテナに入れないときは BusyBox 版 `flock` の機能不足を疑う。`apk add util-linux` で解決した(本記事執筆時点)。Cursor の Alpine 対応はベータで、`bash`・`libstdc++` 等の追加要件がある。
- `external: true` のネットワークは Compose が作成しないため、参照先の compose を先に起動する。Dev Container の問題に見えて実は起動順序、というケースがある。

同じ症状でも原因の層が違えば対処はまったく別物になります。次に「Connecting…」で止まったら、ダイアログを閉じてまず `docker compose ps` と `dmesg` から始めてみてください。

## 参考文献

### 公式ドキュメント

- BusyBox Project. (2026). *util-linux/flock.c*(ソースコード). 2026年7月閲覧. https://git.busybox.net/busybox/tree/util-linux/flock.c
- Cursor. (2024). *Cursor Changelog 0.22.0*. 2026年7月閲覧. https://cursor.com/changelog/0-22-0
- Development Containers. (2026). *Development Containers Specification*. 2026年7月閲覧. https://containers.dev/implementors/spec/
- Docker Inc. (2026). *Compose file reference: Networks*. 2026年7月閲覧. https://docs.docker.com/reference/compose-file/networks/
- Microsoft. (2026a). *Advanced settings configuration in WSL*. 2026年7月閲覧. https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- Microsoft. (2026b). *Linux Prerequisites for Visual Studio Code Remote Development*. 2026年7月閲覧. https://code.visualstudio.com/docs/remote/linux
- util-linux. (2026). *flock(1) — Linux manual page*. 2026年7月閲覧. https://man7.org/linux/man-pages/man1/flock.1.html

### Web記事

- Cursor Forum. (2025). *Dev Containers cannot connect to alpine container in cursor*. 2026年7月閲覧. https://forum.cursor.com/t/dev-containers-cannot-connect-to-alpine-container-in-cursor/49601
