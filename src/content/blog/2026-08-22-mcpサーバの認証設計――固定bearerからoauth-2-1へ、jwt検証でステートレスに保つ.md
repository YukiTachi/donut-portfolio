---
title: MCPサーバの認証設計――固定BearerからOAuth 2.1へ、JWT検証でステートレスに保つ
description: 自作MCPサーバの認証を固定ベアラートークンからOAuth 2.1へ移す設計を、MCP仕様の現行版（2026-07-28）と関連RFCの原文にあたって整理します。結論は、MCPサーバはリソースサーバに徹し、認可判断をJWTの署名検証だけで完結させるのが現実解だということです。あわせて、Dynamic Client RegistrationがClient
  ID Metadata Documentsに置き換わり非推奨になったという、この領域の大きな変更も追いました。
pubDate: 2026-08-22T19:00:00.000+09:00
author: Yuki Tachi
tags:
  - MCP
  - OAuth
  - 認証・認可
  - JWT
  - セキュリティ
  - Model Context Protocol
draft: true
---

## はじめに

以前の記事「[自作MCPサーバのキャッシュ設計](/blog/2026-07-04-自作mcpサーバのキャッシュ設計読み取り専用静的ワークロードでツール別に戦略を変える/)」のとおり、筆者が運用するMCPサーバの認証は固定のベアラートークンです。自分ひとりなら十分ですが、汎用のMCPクライアントから接続させるとなると、失効・ローテーション・スコープ対応が手作業になります。

MCP（Model Context Protocol）の仕様は、これにOAuth 2.1ベースの認可を定めています。本記事では「固定Bearer → OAuth 2.1」への移行を題材に、MCPサーバ側で何を実装し何を実装しないのかを、仕様の現行版（2026-07-28）とIETFの原文を根拠に整理します。

## 背景・課題

OAuthは認証（誰であるか）ではなく認可（何にアクセスしてよいか）のフレームワークです。本記事でも両者は区別します。

MCP仕様において認可は任意（OPTIONAL）で、HTTPベースのトランスポートを使う実装は本仕様に準拠すべき（SHOULD）、stdioを使う実装は従うべきでない（SHOULD NOT）とされています（Model Context Protocol, 2026a）。HTTPで公開するサーバだけの問題です。

要点は役割分担です。保護されたMCPサーバはOAuth 2.1の**リソースサーバ**、トークンを発行する**認可サーバ**は別の役割で、仕様は認可サーバを「実装の詳細は本仕様の範囲外」と明記しています（同）。「認可サーバを自作するな」という経験則以前に、仕様自体が自作対象を絞り込んでいます。なおOAuth 2.1はRFCではなくInternet-Draftで、2026年8月時点の最新は `draft-ietf-oauth-v2-1-15`（2026年3月2日版）です（Hardt et al., 2026）。

発見のフローの起点は401です。MCPサーバはOAuth 2.0 Protected Resource Metadata（RFC 9728）を実装しなければならず、クライアントは認可サーバの発見にこれを使わなければなりません（MUST）（同）。

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource",
                         scope="files:read"
```

## 本論

### PKCEは「オプション」ではない

PKCE（Proof Key for Code Exchange、RFC 7636）は、クライアントが乱数 `code_verifier` とそのハッシュ `code_challenge` の組を作り、認可リクエストでハッシュを、トークンリクエストで元の値を送る仕組みです（Sakimura et al., 2015）。認可コードだけを盗んでも交換できません。

「モバイルアプリ向けのオプション」という理解は古いものです。OAuth 2.0のセキュリティBCPであるRFC 9700は2.1.1節で「パブリッククライアントはPKCEを使わなければならない（MUST）」と定め（Lodderstedt et al., 2025）、MCP仕様はさらに、クライアントは**認可へ進む前にサポートを検証しなければならず**（MUST）、メタデータに `code_challenge_methods_supported` がなければ続行を拒否しなければならない（MUST refuse to proceed）としています（Model Context Protocol, 2026c）。この攻撃面はWebモデル上で形式的に解析されており（Fett et al., 2016）、PKCE前提の根拠は経験則ではありません。

### Dynamic Client Registrationは非推奨になっていた

下調べで筆者の認識をいちばん更新させられた点です。不特定のクライアントが事前登録なしに接続してくるMCP固有の事情から、動的クライアント登録（DCR、RFC 7591）が定番だと理解していました。

しかし現行仕様では、認可サーバとクライアントは**OAuth Client ID Metadata Documents**（CIMD）をサポートすべき（SHOULD）とされ、DCRはサポートしてもよい（MAY）へ格下げのうえ「非推奨であり、後方互換性のために残されている」と明記されています（Model Context Protocol, 2026a; 2026b）。CIMDはHTTPS URLそのものを `client_id` とし、そのURLが `client_id`・`client_name`・`redirect_uris` を含むJSON文書を指す方式です。

区別すべきは、**非推奨になったのはMCPにおけるDCRの位置づけであって、RFC 7591そのものではない**点です。RFC 7591は今もProposed Standardとして有効で、廃止（obsolete）はされていません（Richer et al., 2015）。リソースサーバ側から見れば、登録の受け口はもともと認可サーバの責務で、CIMDでは受け口自体が消えます。

### JWT検証でステートレスに保つ

設計の核です。MCPサーバはOAuth 2.1の5.2節に従ってアクセストークンを検証し、それが**自分自身を対象（audience）として発行された**ことをRFC 8707の2節に従って検証しなければなりません（MUST）（Model Context Protocol, 2026a）。

トークンを署名付きJWT（RFC 7519）にしRFC 9068のプロファイルに沿わせれば、これは公開鍵の検証だけで完結します。RFC 9068が求めるのは、署名をRFC 7515に従って検証すること、`typ` が `at+jwt` であること、`iss` が発行者識別子と完全一致すること、`aud` に自分を指すリソース指示子が含まれること、`alg` が `none` のJWTを拒否すること、現在時刻が `exp` より前であることの6点です（Bertocci, 2021）。Node.jsなら `jose` が対応します（Panva, 2026）。

```typescript
import { createRemoteJWKSet, jwtVerify } from "jose";

const JWKS = createRemoteJWKSet(
  new URL("https://auth.example.com/.well-known/jwks.json"),
);

const { payload } = await jwtVerify(token, JWKS, {
  issuer: "https://auth.example.com",   // iss
  audience: "https://mcp.example.com",  // aud = 自サーバの正規URI
  typ: "at+jwt",                        // RFC 9068
  requiredClaims: ["sub", "client_id", "jti"],
});
```

この検証はどこにも問い合わせに行きません。外部I/Oはゼロで、セッションストアもDBも要りません。前回の記事で「読み取り専用・静的」が設計を単純化したのと同じ構造です。

代償は、JWTが**即時失効できない**ことです。仕様も、認可サーバは短命のアクセストークンを発行すべき（SHOULD）としています（Model Context Protocol, 2026c）。即時失効が要件ならRFC 7662のToken Introspectionで都度照会する手もあります（Richer, 2015）。筆者のサーバは読み取り専用のため、短命JWTで釣り合うと判断しました。

### 移行期に踏んではいけない地雷

この判断は仕様の進み方とも噛み合います。2026-07-28版のStreamable HTTPは、変更点として「**プロトコルレベルのセッションの削除**」を明示しました（Model Context Protocol, 2026d）。トランスポート層がセッションを捨てたのに認証層だけがセッションストアを抱えるのは筋が悪い、というのが筆者の見立てです。

移行期は固定BearerとJWTを並行受理して既存クライアントを壊さない方針ですが（筆者の設計判断）、避けるべき近道が一つあります。上流のAPIを叩く場合、**クライアントから受け取ったトークンをそのまま転送してはなりません（MUST NOT）**。上流のトークンは別物です。Confused Deputy（混乱した代理人）攻撃への対策として、仕様はパススルーを明示的に禁じています（Model Context Protocol, 2026c）。

## 実践への応用・考察

持ち帰れるのは2点です。第一に、**境界線の引き方**。「認可サーバを自作するな」は「全部を外部に任せろ」ではありません。仕様が認可サーバの実装詳細を範囲外と書く以上、自作すべきはリソースサーバ側の検証だけで、中身は署名・`iss`・`aud`・`exp`・スコープの5点に縮まります。認証の設計とは、機能を足す作業ではなく責務を削る作業でした。

第二に、**ステートレスにできる場所はステートレスに保つ**。キャッシュ設計では「読み取り専用・静的」がキャッシュ無効化を消し、認証では「JWT＋短命トークン」がセッションストアを消します。前提が崩れれば成り立たない点まで同じです。

限界も書いておきます。DCRが「定番」から「非推奨」へ移ったとおり、この領域の記述は寿命が短く、RFC番号と仕様バージョンを明記したのはそのためです。CIMDの基となる `draft-ietf-oauth-client-id-metadata-document-00` もまだdraft-00です。

## まとめ

- MCPサーバはOAuth 2.1の**リソースサーバ**であり、認可サーバの実装詳細は仕様の範囲外。自作するのは検証側だけでよい。
- クライアントはPKCEを実装しなければならず、`code_challenge_methods_supported` が確認できなければ続行を拒否しなければならない。
- DCRは現行仕様で**非推奨**となりCIMDが推奨経路になった。ただしRFC 7591自体は有効な標準のまま。
- RFC 9068準拠のJWTなら検証は公開鍵だけで完結する。代償の即時失効不能は短命トークンとローテーションで補う。
- 上流APIへのトークンのパススルーは禁止（MUST NOT）。

次に手を動かすなら、`/.well-known/oauth-protected-resource` を1本立てて401に `WWW-Authenticate` を足すところからです。責務の小ささを実装量で体感できます。

## 参考文献

### 学術論文

- Fett, D., Küsters, R., & Schmitz, G. (2016). A Comprehensive Formal Security Analysis of OAuth 2.0. *Proceedings of the 2016 ACM SIGSAC Conference on Computer and Communications Security (CCS '16)*, 1204-1215. https://doi.org/10.1145/2976749.2978385

### 公式ドキュメント

- Bertocci, V. (2021). *RFC 9068: JSON Web Token (JWT) Profile for OAuth 2.0 Access Tokens*. IETF. https://doi.org/10.17487/RFC9068
- Campbell, B., Bradley, J., & Tschofenig, H. (2020). *RFC 8707: Resource Indicators for OAuth 2.0*. IETF. https://doi.org/10.17487/RFC8707
- Hardt, D., Parecki, A., & Lodderstedt, T. (2026). *The OAuth 2.1 Authorization Framework* (draft-ietf-oauth-v2-1-15, 2026年3月2日版). IETF. 2026年8月閲覧. https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1-15
- Jones, M., Bradley, J., & Sakimura, N. (2015). *RFC 7515: JSON Web Signature (JWS)*. IETF. https://doi.org/10.17487/RFC7515
- Jones, M., Bradley, J., & Sakimura, N. (2015). *RFC 7519: JSON Web Token (JWT)*. IETF. https://doi.org/10.17487/RFC7519
- Jones, M., Hunt, P., & Parecki, A. (2025). *RFC 9728: OAuth 2.0 Protected Resource Metadata*. IETF. https://doi.org/10.17487/RFC9728
- Lodderstedt, T., Bradley, J., Labunets, A., & Fett, D. (2025). *RFC 9700: Best Current Practice for OAuth 2.0 Security*. IETF. https://doi.org/10.17487/RFC9700
- Model Context Protocol. (2026a). *Authorization*（仕様バージョン 2026-07-28）. 2026年8月閲覧. https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization
- Model Context Protocol. (2026b). *Client Registration*（仕様バージョン 2026-07-28）. 2026年8月閲覧. https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration
- Model Context Protocol. (2026c). *Authorization Security Considerations*（仕様バージョン 2026-07-28）. 2026年8月閲覧. https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations
- Model Context Protocol. (2026d). *Streamable HTTP*（仕様バージョン 2026-07-28）. 2026年8月閲覧. https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
- Panva. (2026). *jose: JWTVerifyOptions*. GitHub. 2026年8月閲覧. https://github.com/panva/jose/blob/main/docs/jwt/verify/interfaces/JWTVerifyOptions.md
- Richer, J. (Ed.). (2015). *RFC 7662: OAuth 2.0 Token Introspection*. IETF. https://doi.org/10.17487/RFC7662
- Richer, J. (Ed.), Jones, M., Bradley, J., Machulak, M., & Hunt, P. (2015). *RFC 7591: OAuth 2.0 Dynamic Client Registration Protocol*. IETF. https://doi.org/10.17487/RFC7591
- Sakimura, N. (Ed.), Bradley, J., & Agarwal, N. (2015). *RFC 7636: Proof Key for Code Exchange by OAuth Public Clients*. IETF. https://doi.org/10.17487/RFC7636
