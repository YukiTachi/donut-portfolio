---
title: 本番では動くのにローカルでは繋がらないMCPサーバ――Content-LengthとSSEの矛盾を層別テストで切り分ける
description: 同じコードのMCPサーバが、nginx経由の本番では動くのに、ローカルDockerへClaude Desktop＋mcp-remoteで繋ぐとinitializeが60秒でタイムアウトしました。curlで見つけた「text/event-streamにContent-Lengthが付く」矛盾レスポンスをRFC 9112とNode.jsのソースで読み解き、Expressで修正しても失敗が残った経緯を、curl・Claude Code直結・mcp-remoteの対照表で切り分けます。結論は、最初に見つけた異常が原因とは限らず、仲介層も容疑者に含めて層別に消していく、ということです。
pubDate: 2026-09-06T19:00:00.000+09:00
author: Yuki Tachi
tags:
  - MCP
  - Model Context Protocol
  - HTTP
  - Node.js
  - nginx
  - トラブルシューティング
  - Claude Code
draft: true
---

## はじめに

本番では動く。コードは同じ。なのにローカルだけ、MCPクライアントからの `initialize` が60秒で死ぬ――2026年7月下旬に筆者が踏んだ事象です。差分がコードにないなら、差分は経路にあります。

本記事は、自作MCP（Model Context Protocol）サーバをローカル開発するエンジニア向けに、この切り分けを実録として整理します。「[キャッシュ設計](/blog/2026-07-04-自作mcpサーバのキャッシュ設計読み取り専用静的ワークロードでツール別に戦略を変える/)」「[認証設計](/blog/2026-08-22-mcpサーバの認証設計固定bearerからoauth-2-1へjwt検証でステートレスに保つ/)」に続くトランスポート編で、実ドメイン・ポート・トークンは例示値です。

## 背景・課題

構成は次のとおりです。

- MCPサーバ: Node.js + Express、トランスポートはStreamable HTTP
- 本番: nginxを前段に置き、TLS終端とリバースプロキシを担当
- ローカル: Dockerで同じイメージをnginxなしで直接公開（ポート `3000` は例示値）
- クライアント: Claude Desktop。設定ファイルで起動できるのは `command` と `args` で子プロセスを立ち上げるstdio型サーバなので（Model Context Protocol, 2026c）、`npx mcp-remote <URL>` を挟んでHTTPへ橋渡し

mcp-remoteは「stdioしか話せないMCPクライアントをリモートMCPサーバへつなぐ」npmパッケージです（punkpeye, 2026）。本番とローカルの違いは、HTTPの手前にnginxがいるかどうかだけでした。

仕様側では、現行バージョン 2026-07-28（Model Context Protocol, 2026b）において、サーバはJSON-RPCリクエストに対し単一のJSON（`application/json`）かSSE（Server-Sent Events）ストリーム（`text/event-stream`）のどちらかを返さなければならず、SSEの場合は最終のJSON-RPCレスポンスがストリームを終端すべき（SHOULD）とされています（Model Context Protocol, 2026a）。`initialize` へのSSE応答は「イベントを1つ流して閉じる」短命なストリームです。

## 本論

### 観察――curlで生ヘッダを取る

MCPクライアントを疑う前に、サーバが何を返しているかを生で見ます。

```sh
curl -v -X POST http://localhost:3000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Authorization: Bearer ****' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}'
```

```http
HTTP/1.1 200 OK
content-type: text/event-stream
content-length: 412
connection: keep-alive
```

curlは正常終了し、本文には `initialize` 結果を載せたSSEイベントが1つ入っていました。処理自体は正しい。しかしこの3行は矛盾しています。

### 読み解き――RFC 9112のメッセージ長決定規則

HTTP/1.1の本文長はRFC 9112の6.3節の規則で決まります（Fielding et al., 2022）。規則3は「`Transfer-Encoding` と `Content-Length` が両方あれば前者が優先」、規則6は「有効な `Content-Length` が `Transfer-Encoding` なしで存在すれば、その値が本文長」、規則8は「応答にどちらもなければ、サーバが接続を閉じるまでが本文」です。

ローカルの応答は規則6です。`content-length: 412` は「本文は412バイトで終わり」の宣言で、curlが412バイト読んで終了するのは仕様どおりです。一方、WHATWGのHTML仕様はSSEについて「こうしたリソースへの接続は長寿命であることが期待される」と述べています（WHATWG, 2026）。**同じレスポンスでも、HTTPの規則で読むクライアントとSSEの前提で読むクライアントでは解釈が割れうる**のが、この矛盾の本質です。ただし、仕様上おかしいことと、目の前のタイムアウトの原因であることは別です。

### 本番が動く理由の推定――中間層が不備を直す

当時の推定は「nginxが `Content-Length` を落とし、chunked転送に変えて返していた」でした。ただし本番側で `curl -v` を取って裏付けてはいません（真っ先に取るべき測定でした）。仕様根拠で言える範囲では、RFC 9112は両方のヘッダを受信した中間者が転送するなら `Content-Length` を除去しなければならない（MUST）と定め（Fielding et al., 2022）、nginxはHTTP/1.1のchunked転送と `proxy_buffering` を既定で有効にし（nginx, 2026a; 2026b）、gzipが掛かれば本文長が変わるので `Content-Length` はそのまま通せません（nginx, 2026c）。本番設定がどれを踏んでいたかは検証材料がなく、**推定のまま**です。

教訓は明確です。**リバースプロキシはアプリの不備を黙って直すことがある**。「本番では動く」が不具合を隠します。

### 修正――Node.jsがContent-Lengthを自動付与する条件

Node.jsのドキュメントは、`Content-Length` が未設定ならデータは自動的にchunked転送になると述べています（Node.js, 2026a）。では自動で付くのはいつか。`lib/_http_outgoing.js` では、ヘッダ未送信の状態で `end()` に本文が渡されるとそのバイト長が `_contentLength` に記録され、`_removedContLen` が立っておらず `_contentLength` が数値なら `Content-Length` を書き出し、そうでなければchunkedを選びます（Node.js, 2026b）。SSEイベント1つを丸ごと `end()` に渡すと、Node.jsは親切に長さを数えてしまうわけです。筆者のサーバでどの層がこの経路を通ったかは特定していません（推定）。

対処は `removeHeader('Content-Length')`（`_removedContLen` を立てる）と `flushHeaders()`（本文より先にヘッダを確定させる）の組み合わせです。

```typescript
import type { Request, Response, NextFunction } from 'express';

export function sseFraming(_req: Request, res: Response, next: NextFunction) {
  const origWriteHead = res.writeHead.bind(res);
  res.writeHead = ((...args: Parameters<typeof origWriteHead>) => {
    const result = origWriteHead(...args);
    if (String(res.getHeader('Content-Type') ?? '').startsWith('text/event-stream')) {
      res.removeHeader('Content-Length');
      res.flushHeaders();
    }
    return result;
  }) as typeof res.writeHead;
  next();
}
```

再びcurlで確認すると `content-length` が消え、`transfer-encoding: chunked` が付きました。

### それでも失敗する――容疑者はまだ残っている

ところが、Claude Desktop + mcp-remote 経由の `initialize` は修正後も60秒でタイムアウトしました。

直した層が間違っていたのではなく、**容疑者がまだ残っている**のです。残るのはmcp-remote、SDK、プロトコル解釈の3つ。一度に絞る手として、Claude CodeはHTTPトランスポートのMCPサーバを直接登録でき、`claude mcp list` が接続状態を表示します（Anthropic, 2026）。

```sh
claude mcp add --transport http local-mcp http://localhost:3000/mcp \
  --header "Authorization: Bearer ****"
claude mcp list
```

結果は即 `✔ Connected`。同じサーバ、同じSSE応答で、違うのは仲介層だけです。

| 経路 | クライアント | 結果 |
|------|--------------|------|
| curl → ローカル | curl | 正常（修正前後とも） |
| Claude Code → ローカル | HTTP直結 | 即 Connected |
| Claude Desktop → mcp-remote → ローカル | mcp-remote 0.1.38 | 60秒タイムアウト（修正前後とも） |
| Claude Desktop → mcp-remote → nginx → 本番 | mcp-remote 0.1.38 | 正常 |

Claude Codeの直結が同じサーバと会話できている以上、サーバとプロトコルは容疑から外れ、残るのはmcp-remoteです。当時npmの最新版は 0.1.38（2026年2月5日公開）で、事象の時点で約5か月半、新しいリリースがありませんでした。**言えるのは「mcp-remote 0.1.38 とローカル直接公開の組み合わせでは失敗し、他では成功する」まで**で、内部のどこで詰まったかは特定していません。

### 執筆時点の現況――事実だけを書く

執筆時（2026年9月）に再確認すると状況は変わっていました。npmでは 0.1.39 が2026年8月21日に公開され、以後8月31日の 0.8.3 まで短期間にリリースが続いています。`repository.url` は 0.1.38 の `github.com/geelen/mcp-remote` から 0.8.3 では `github.com/punkpeye/mcp-remote` に変わり、READMEは「Glen Maddern が原作者」と明記したうえで、タイムアウト設定やトランスポート戦略を説明しています（npm, 2026; punkpeye, 2026）。

当時の事象を現行版で再現試験していないため、「直った」とも「直っていない」とも書けません。OSSの仲介層を容疑に含めることと、その品質を断ずることは別です。

## 実践への応用・考察

持ち帰れるのは3点です。

**1. 矛盾ヘッダはクライアントごとに解釈が割れる**。`Content-Length` と `text/event-stream` の同居は、RFC 9112の規則6に従うクライアントには有限長の応答に見え、SSEの長寿命前提に立つクライアントには別の意味に見えます。

**2. 本番とローカルの差は、コードより先に中間層を疑う**。「本番で動く」は、リバースプロキシが不備を吸収している状態かもしれません。本番でも `curl -v` を取っておけば、推定は事実に置き換えられていました。

**3. 修正が効かないときは、残った容疑者を消す**。最初に見つけた異常は本物でしたが、原因ではありませんでした。同じサーバに別のクライアントで同じ操作をする対照実験が、層を一つずつ消してくれます。

運用上の結論は経路の分離です。ローカル開発はClaude CodeのHTTP直結、Claude Desktopには本番URLだけを登録します。なお現行仕様は、SSE開始時に `X-Accel-Buffering: no` を送ってリバースプロキシの応答バッファリングを無効化することを推奨（SHOULD）しており（Model Context Protocol, 2026a）、仕様自体が中間層を想定して書かれています。

## まとめ

- `text/event-stream` に `Content-Length` が付く応答は、RFC 9112の規則6では有限長の応答に見える。仕様上の矛盾であり、サーバ側で直す
- Node.jsはヘッダ未送信のまま `end()` に本文を渡すと `Content-Length` を自動付与する。SSEでは `removeHeader` と `flushHeaders()` でchunkedに寄せる
- 「本番では動く」はリバースプロキシが直している可能性がある。本番でも生ヘッダを測る
- 修正しても失敗が残るなら容疑者が残っている。curl／Claude Code直結／mcp-remoteの対照実験で層ごとに消す
- 仲介層のOSSは更新日の事実で判断する。執筆時点でmcp-remoteは活発に更新されている

次に手を動かすなら、自分のMCPサーバに `initialize` を `curl -v` で投げ、`content-type`・`content-length`・`transfer-encoding` の3行を見るところからです。経路の議論を事実から始められます。

## 参考文献

### 学術論文

本記事は技術トピックのため、査読付き論文ではなく、標準仕様・公式ドキュメント・ソースコードといった一次資料を根拠としています。

### 公式ドキュメント

- Anthropic. (2026). *Connect Claude Code to tools via MCP*. Claude Code Docs. 2026年9月閲覧. https://code.claude.com/docs/en/mcp
- Fielding, R., Nottingham, M., & Reschke, J. (2022). *RFC 9112: HTTP/1.1*. IETF. https://doi.org/10.17487/RFC9112
- Model Context Protocol. (2026a). *Streamable HTTP*（仕様バージョン 2026-07-28）. 2026年9月閲覧. https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
- Model Context Protocol. (2026b). *Versioning*. 2026年9月閲覧. https://modelcontextprotocol.io/specification/versioning
- Model Context Protocol. (2026c). *Connect to local MCP servers*. 2026年9月閲覧. https://modelcontextprotocol.io/docs/develop/connect-local-servers
- nginx. (2026a). *Module ngx_http_core_module*. 2026年9月閲覧. https://nginx.org/en/docs/http/ngx_http_core_module.html
- nginx. (2026b). *Module ngx_http_proxy_module*. 2026年9月閲覧. https://nginx.org/en/docs/http/ngx_http_proxy_module.html
- nginx. (2026c). *Module ngx_http_gzip_module*. 2026年9月閲覧. https://nginx.org/en/docs/http/ngx_http_gzip_module.html
- Node.js. (2026a). *HTTP | Node.js v26.8.1 Documentation*. 2026年9月閲覧. https://nodejs.org/api/http.html
- Node.js. (2026b). *lib/_http_outgoing.js*（main ブランチ）. GitHub. 2026年9月閲覧. https://github.com/nodejs/node/blob/main/lib/_http_outgoing.js
- npm. (2026). *mcp-remote*（バージョン 0.8.3、2026年8月31日公開。0.1.38 は2026年2月5日公開）. 2026年9月閲覧. https://www.npmjs.com/package/mcp-remote
- punkpeye. (2026). *mcp-remote: README*. GitHub. 2026年9月閲覧. https://github.com/punkpeye/mcp-remote
- WHATWG. (2026). *HTML Living Standard: 9.2 Server-sent events*. 2026年9月閲覧. https://html.spec.whatwg.org/multipage/server-sent-events.html
