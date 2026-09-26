---
title: MCP Connectorにローカルの自作MCPサーバを繋ぐ――Cloudflare Tunnelと接続トポロジの話
description: ローカルで動くMCPサーバ、検証済みのトークン、それでもチャットは「接続に問題が発生しています」と言う――原因はコードではなく、接続の向きでした。Messages APIのMCP Connectorでは、MCPサーバに接続しに来るのは自分のマシンではなくAnthropic側のサーバです。localhostやhost.docker.internalが原理的に使えない理由を公式ドキュメントで確認し、cloudflaredのクイックトンネルで公開経路を作るまでの切り分けと、トンネルをどこで起動するか・何を防壁にするかという運用設計をまとめます。
pubDate: 2026-09-22T03:00:00.000+09:00
author: Yuki Tachi
tags:
  - MCP
  - Model Context Protocol
  - Anthropic API
  - Cloudflare Tunnel
  - Docker
  - ローカル開発
  - トラブルシューティング
draft: true
---

## はじめに

トークンは検証済み、MCPサーバもローカルで起動している。なのにチャット画面は「AIサービスの接続に問題が発生しています」としか言わない――2026年9月に筆者が踏んだ事象です。

結論から書くと、原因はコードでもトークンでもなく、**接続の向き**でした。Messages APIのMCP Connectorを使う構成では、MCPサーバに接続しに来るのは自分のマシンではなく、Anthropic側のサーバです。この一点を理解しておらず、「手元のcurlでは200が返るのに本番経路では絶対に動かない」状態を自分で作り込んでいました。

本記事は、自作のMCP（Model Context Protocol）サーバをLLMアプリに組み込むエンジニア向けに、接続トポロジの整理、障害点に直接触る切り分け、cloudflaredのクイックトンネルによる実用解と運用設計を実録として整理します。ポート番号とエラー文言は実際のものですが、プロダクト名とドメインは伏せています。

## 背景・課題

構成は次のとおりです。

- アプリ: Next.jsのAPIルート（`/api/chat`）がAnthropicのMessages APIを呼ぶ
- ツール: 自作のMCPサーバ（Streamable HTTP、Bearerトークン認証）をMCP Connector経由で接続
- 開発環境: WSL2上のDockerコンテナでアプリを動かし、MCPサーバはホスト側のポート `5100` で起動

MCP Connectorは、別途MCPクライアントを実装しなくても、Messages APIから直接リモートMCPサーバへ繋げる機能です（Anthropic, 2026）。執筆時点のベータヘッダは `mcp-client-2025-11-20` で、以前の `mcp-client-2025-04-04` は非推奨です。リクエストは2部構成で、`mcp_servers` 配列にサーバの接続情報（`type`・`url`・`name`・`authorization_token`）を書き、`tools` 配列に `mcp_toolset` を置いて有効にするツールを設定します。片方だけでは通りません。定義したMCPサーバはちょうど1つのMCPToolsetから参照されていなければならない、と検証ルールに明記されています（Anthropic, 2026）。なおMCPの現行プロトコル版は 2026-07-28 です（Model Context Protocol, 2026a）。

ここで見落としていたのが、同じドキュメントの制限事項に書かれた一文です。

> The server must be publicly exposed through HTTP (supports both Streamable HTTP and SSE transports). Local STDIO servers cannot be connected directly.（Anthropic, 2026）

サーバはHTTPで**公開されていなければならない**。`url` の説明にも「Must start with https://」とあります。筆者はこれを「HTTPSで喋れるサーバならよい」と読んでいましたが、実際には「インターネットから到達できなければならない」という意味でした。

## 本論

### 障害点に直接触る――アプリのエラー表示は層が違う

最初に見えていたのは、チャットUIの「AIサービスの接続に問題が発生しています」という文言だけでした。この手のメッセージは、たいてい自分で書いたエラーハンドリングの産物です。実際、`app/api/chat/route.ts` を読み直すと、Anthropic APIが返した400を握りつぶして502に変換していました。

```ts
// 400（リクエスト不正）も500系も同じ扱いにしていた例
catch (err) {
  return NextResponse.json({ error: "AIサービスの接続に問題が発生しています" }, { status: 502 });
}
```

400は「あなたのリクエストがおかしい」、502は「上流が落ちている」で、意味がまったく違います。これを潰していたせいで、最初の数十分を「Anthropic側の障害では」という誤った仮説に使いました。

そこでアプリを介さず、MCPエンドポイントに直接触ります。

```sh
curl -i -X POST http://localhost:5100/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Authorization: Bearer ****'
```

返ってきたのは403でした。本番用トークンをローカルにも配って使い回しており、それが失効していたのです。MCPの仕様はStreamable HTTPのサーバに「すべての接続に適切な認証を実装すべき（SHOULD）」と求めており（Model Context Protocol, 2026b）、認証が効いているからこその403でした。

### 分離の判断と、その直後に潜伏した問題

トークン失効は再発行で直りますが、本番トークンをローカル開発機にも配る運用自体が筋の悪いものです。[MCPサーバの認証設計](/blog/2026-08-22-mcpサーバの認証設計固定bearerからoauth-2-1へjwt検証でステートレスに保つ/)で整理したとおり、資格情報は用途ごとに分けるのが前提です。そこでローカル専用のMCPサーバとトークンに分離し、`.env` のURLをコンテナからホストを指す名前に変えました。

```ini
MCP_SERVER_URL=http://host.docker.internal:5100/mcp
```

ローカルからのcurlは200を返し、トークンも通ります。にもかかわらず、チャットは動きませんでした。**検証はすべて通るのに本番経路では絶対に動かない状態が、ここで完成しています。**

### 核心――接続しに来るのは自分のマシンではない

MCP Connectorで `mcp_servers[].url` のアドレスへ接続しに行くのはAnthropicのサーバであって、自分のマシンではありません。URLは相手から見て到達可能でなければならない。`localhost` は相手にとっては相手自身を指しますし、`host.docker.internal` はDockerの特別なDNS名で、「ホストが使う内部IPアドレスに解決される」ものです（Docker, 2026）。どちらもマシンの内側でしか意味を持たず、インターネットから到達する手段がありません。原理的に不可能だったわけです。

ここでは、接続トポロジが2種類あるという整理が効きます。

| | クライアント接続型 | サーバ接続型（MCP Connector） |
|---|---|---|
| 接続を開始する側 | 手元のMCPクライアント | Anthropicのサーバ |
| 到達性の要件 | 手元から見えればよい | インターネットから到達可能 |
| ローカル開発 | `localhost` 直結で足りる | 公開経路が必須 |

デスクトップアプリやCLIのMCPクライアントは前者で、`localhost` のままで開発が完結します。MCP Connectorは後者で、矢印の向きが逆になります。

一般化すると、**自分の手元で検証が通ることと、相手から届くことは別物**です。手元のcurlは「自分から自分へ」の経路を確かめただけで、本番の経路（相手から自分へ）は一度も通っていませんでした。[証明書のトラブルシュート](/blog/2026-08-02-lets-encrypt証明書のトラブルシュート実践メール証明書エラー1件から自動更新の設計不備を洗い出す/)のときと同じ構図で、検証した経路が本番の経路と違うという失敗です。

### 解決――クイックトンネルで公開経路を作る

必要なのは、ローカルのポートへインターネットから到達できる一時的な入口です。Cloudflareのクイックトンネル（TryCloudflare）は、ドメインをCloudflareのDNSに追加しなくても `trycloudflare.com` のランダムなサブドメインを生成し、Cloudflareのネットワーク経由でローカルのWebサーバへリクエストをプロキシします（Cloudflare, 2026）。

```sh
cloudflared tunnel --url http://localhost:5100
# → https://<ランダム>.trycloudflare.com が標準出力に表示される
```

あとは `.env` を差し替えるだけです。

```ini
MCP_SERVER_URL=https://<ランダム>.trycloudflare.com/mcp
```

設計判断は3点ありました。

1. **トンネルはWSL2コンテナの中ではなく、Windowsホスト側で起動する。** コンテナの再起動にトンネルが巻き込まれると、そのたびURLが変わって `.env` を書き直すことになります。ライフサイクルの違うものを同じ箱に入れない、という判断です。
2. **公開の防壁はMCPサーバ自身のBearer認証に持たせる。** トンネルは経路を作るだけで、認可はしません。同じMCP仕様は、ローカル実行時にはサーバを `0.0.0.0` ではなく `127.0.0.1` にバインドすべき（SHOULD）とも述べています（Model Context Protocol, 2026b）。トンネルを張るのはこの推奨の外に自分で出ることなので、認証は前提条件になります。
3. **検証は必ずトンネルURL経由で行ってから、アプリのE2Eに進む。** 同じ `curl` を、今度は外部経路に対して撃ちます。これで「相手から届く」ことを確かめたことになります。

筆者の環境（2026年9月21日）では、トンネルURL経由でMCPの認証が通ることを確かめたうえで、チャットAPIのE2Eで応答がストリーミングで返り、ブラウザからも動くところまで確認しました。

## 実践への応用

この解決策には隠しておくべきでない弱点があります。クイックトンネルは起動のたびにURLが変わるので、そのつど `.env` の更新が要ります。そしてCloudflareは「クイックトンネルはテストと開発のみを想定している」「TryCloudflareのSLAや稼働率は保証しない」と明記しています（Cloudflare, 2026）。恒常的に使うなら名前付きトンネルへの移行が筋です。筆者はまだ移行していませんが、URLの書き換えが頻発するなら移行コストのほうが安い、というのが主観的な感触です。

もう1つ、同じページの制限事項には「Quick Tunnels do not support Server-Sent Events (SSE).」とあります（Cloudflare, 2026）。Streamable HTTPのMCPサーバはSSEで応答することがあり、本来は相性の悪い組み合わせです。筆者の環境ではトンネル経由の認証確認からチャットのE2Eまで通りましたが、これは実測の範囲の話で、公式にサポートされた構成ではありません。

切り分けの手順は、次の順序が再利用できます。

1. アプリのエラー表示を信じない。自分のコードが上流のステータスコードを潰していないか、まずエラーパスを読む
2. 障害点に直接触る。アプリを介さず、`curl` でエンドポイントそのものに当てる
3. 通った経路と、本番で使われる経路が同じか確認する。違うなら、その検証は本番の証拠になっていない

3番目が今回の教訓です。外部サービス連携では、**接続をどちらが開始するのか**を最初に問う価値があります。

## まとめ

- MCP Connectorでは、MCPサーバに接続しに来るのはAnthropicのサーバであり、URLはインターネットから到達可能でなければならない（`localhost` や `host.docker.internal` は原理的に不可）
- リクエストは `mcp_servers` と `tools` の `mcp_toolset` の両方が必要で、現行のベータヘッダは `mcp-client-2025-11-20`
- アプリのエラー表示は自分の実装の産物なので、切り分けでは障害点に直接 `curl` を当てる
- cloudflaredのクイックトンネルは有効な一時解だが、URLは毎回変わり、稼働率の保証もなく、公式にはSSE非対応。防壁はMCPサーバ自身の認証に持たせる
- 検証した経路が本番の経路と同じかを、最後に必ず確認する

次のアクションとしては、名前付きトンネルへの移行と、ローカル専用トークンの有効期限をCIから点検する仕組みを検討しています。

## 参考文献

### 公式ドキュメント

- Anthropic (2026). MCP connector. https://platform.claude.com/docs/en/agents-and-tools/mcp-connector （2026年9月閲覧）
- Cloudflare (2026). TryCloudflare. https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/ （2026年9月閲覧）
- Docker (2026). General FAQs for Docker Desktop. https://docs.docker.com/desktop/troubleshoot-and-support/faqs/general/ （2026年9月閲覧）
- Model Context Protocol (2026a). Versioning. https://modelcontextprotocol.io/specification/versioning （2026年9月閲覧）
- Model Context Protocol (2026b). Streamable HTTP (protocol revision 2026-07-28). https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http （2026年9月閲覧）
