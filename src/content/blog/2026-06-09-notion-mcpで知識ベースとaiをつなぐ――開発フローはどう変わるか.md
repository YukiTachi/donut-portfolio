---
title: Notion MCPで知識ベースとAIをつなぐ――開発フローはどう変わるか
description: Notionに溜めたドキュメントやタスクを、AIエージェントが直接読み書きできるようにするのがNotion MCPです。MCP（Model Context Protocol）はAnthropicが2024年に公開した、AIとデータソースをつなぐオープン標準。本記事では、Notion公式のホスト型MCPサーバー（https://mcp.notion.com/mcp）がどんな仕組みで、なぜMarkdownを採用してトークン効率を上げているのか、そして知識ベースとAIの連携が開発フローをどう変えるのかを、公式ドキュメントに基づいて整理します。
pubDate: 2026-06-09T19:00:00.000+09:00
author: Yuki Tachi
tags:
  - Notion
  - MCP
  - AI
  - Model Context Protocol
  - 開発フロー
  - 生産性
draft: true
---

## はじめに

Notionにドキュメントやタスク、設計メモを溜めているのに、AIに質問するときは結局コピペしている――そんな分断は珍しくありません。MCP（Model Context Protocol）は、この分断を埋めるための仕組みです。AIエージェントがNotionの知識ベースを直接検索し、ページを読み、新しいページを書けるようになります。

本記事では、まずMCPというオープン標準の位置づけを確認し、次にNotion公式のホスト型MCPサーバーの設計を公式ドキュメントから読み解きます。そのうえで、知識ベースとAIをつなぐと開発フローが具体的にどう変わるのかを、活用例とともに整理します。なお本テーマは技術トピックのため、査読付き論文ではなく公式ドキュメント・一次資料を中心に裏付けます。

## 背景・課題

AIアシスタントを業務データにつなぐとき、長らく障害になってきたのが「組み合わせ爆発」です。AIアプリケーション（クライアント）がM種類、つなぎたいデータソースがN種類あると、素朴に実装すればN×M本の専用コネクタが必要になります。Anthropicはこの状況を「新しいデータソースごとに独自実装が必要で、真に接続されたシステムを規模拡大するのが難しい」と表現しています（Anthropic, 2024）。

この課題に対してAnthropicが2024年11月25日に公開したのがMCPです（Anthropic, 2024）。MCPはAIアプリケーションとデータソースをつなぐオープン標準で、開発者は自分のデータをMCPサーバーとして公開するか、それらに接続するAIアプリケーション（MCPクライアント）を作るか、どちらかを選べばよくなります（Anthropic, 2024）。サーバー側が提供する中核要素（プリミティブ）は、プロンプト・リソース・ツールの3種類と定義されています（modelcontextprotocol.io）。USB-Cが周辺機器の接続を一本化したように、MCPはAIとツールの接続規格を一本化しようとするものだと考えると分かりやすいでしょう。

この標準は急速に広がりました。2025年12月9日にMCPはLinux Foundation傘下のAgentic AI Foundationへ寄贈され、その時点で公開されているアクティブなMCPサーバーは1万件を超え、ChatGPT・Cursor・Gemini・Microsoft Copilot・Visual Studio Codeなどに採用されていると報告されています（Anthropic, 2025）。Notionの知識ベース連携も、この共通基盤の上に成り立っています。

## 本論

### Notion公式のホスト型MCPサーバー

Notionは2025年4月初頭にまずオープンソースのMCPサーバーを公開し、その後ホスト型（リモート）サーバーへと軸足を移しました（Notion, 2025）。現在の公式エンドポイントは `https://mcp.notion.com/mcp` で、SSE方式のエンドポイント `https://mcp.notion.com/sse` も用意されています（Notion Developers, 2026）。

認証にはユーザー単位のOAuthが用いられ、ベアラートークン認証はサポートされません。利用前にOAuthフローで認可を済ませる必要があります（Notion Developers, 2026）。ホスト型のため利用者側でサーバーを立てる必要がなく、Notion側がツールを継続的に改善できる点が、オープンソース版から移行した理由として挙げられています（Notion, 2025）。

### なぜMarkdownなのか――トークン効率という設計判断

Notionのホスト型サーバーで特徴的なのは、AIとのやり取りにJSONではなくMarkdownを採用した点です。公式ブログは「MarkdownはLLMのトークンあたりのコンテンツ密度が高く、一般的なユースケースでは（オープンソース版のMCPサーバーより）必要なツール呼び出しが少なく、コストも低い」と説明しています（Notion, 2025）。

これは細かな最適化に見えて、エージェント運用では効いてきます。AIは文脈をトークンとして消費するため、同じ情報をより少ないトークンで表現できれば、1回の対話で扱える知識ベースの範囲が広がり、API利用料も抑えられます。Notionはこの方針のもと、`search`・`create-pages`・`update-page`・`create-comment` といったツールを「AIファースト」に設計・再実装したとしています（Notion, 2025）。

### 知識ベースを検索・生成する

ホスト型サーバーの `search` ツールは、単なるキーワード一致ではなく「質問によるセマンティック検索」に対応し、Notionワークスペースに加えて10種類以上の連携済み外部アプリを横断して関連ページを見つけられます（Notion, 2025）。AIは「先月のリリース手順はどこ？」のような自然言語の問いから該当ドキュメントへ辿り着けます。

書き込み側では、`create-pages` と `update-page` がエージェント向けに書き直されています（Notion, 2025）。たとえば会議メモのページからタスク一覧を抽出して新しいページに整理する、設計判断をドキュメントへ追記する、といった操作をAIに委ねられます。一方で、ファイルアップロードは執筆時点では未対応で、ロードマップ上の機能とされています（Notion Developers, 2026）。連携でできることと、まだできないことを把握しておくのが実務上は重要です。

## 実践への応用・考察

知識ベースとAIをつなぐと、開発フローの「文脈を運ぶ手間」が減ります。これまではNotionの仕様メモをコピーしてAIに貼り、回答をまたNotionに戻す、という往復が発生していました。MCP経由なら、AIエージェントが検索から下書き生成、ページ更新までを一連の操作として実行できます。

筆者の運用では、この仕組みを定型作業の自動化に使っています。具体的には、Notionの「ネタ帳」ページを起点に、AIが未処理項目を1件取り出し、エビデンスを集めて記事の下書きを生成し、完了状態をNotion側に書き戻す――という流れです（この記事自体、その経路で生成された下書きです）。人間が文脈をコピペで運ぶ代わりに、Notionが一次情報源（single source of truth）として機能し、AIがそこを直接読み書きする構図になります。

ただし注意点もあります。第一に、OAuthでワークスペースへの読み書き権限をAIに渡すため、権限の範囲と監査を意識する必要があります。第二に、MCPはあくまで「接続の規格」であって、出力の正しさを保証する仕組みではありません。AIが生成したページの内容は、人間のレビューを前提にすべきです。筆者の経験でも、下書きの自動生成は有用ですが、公開前の確認工程を省くと事実誤りを見落としやすくなります。便利さと検証コストはトレードオフだと捉えるのが現実的です。

## まとめ

- MCPはAIとデータソースをつなぐオープン標準で、2024年11月25日にAnthropicが公開し、2025年12月にLinux Foundationへ寄贈された。
- Notion公式のホスト型MCPサーバー（`https://mcp.notion.com/mcp`）はOAuth認証で、サーバー構築不要で使える。
- やり取りにMarkdownを採用し、トークン効率を高めている点が設計上の要。
- `search`によるセマンティック検索と`create-pages`/`update-page`による生成で、知識ベースを起点にした自動化ができる。
- 権限管理と人間によるレビューは引き続き不可欠で、接続の規格は出力の正しさを保証しない。

まずは小さな定型作業――議事録からのタスク抽出や、ネタ帳を起点にした下書き生成――から、Notionを起点にAIを動かす経路を一つ作ってみてください。文脈をコピペで運ぶ作業が消えることの効きめは、実際に試すと体感しやすいはずです。

## 参考文献

### 公式ドキュメント

- Anthropic. (2024). *Introducing the Model Context Protocol*. 2026年6月閲覧. https://www.anthropic.com/news/model-context-protocol
- Anthropic. (2025). *Donating the Model Context Protocol and establishing the Agentic AI Foundation*. 2026年6月閲覧. https://www.anthropic.com/news/donating-the-model-context-protocol-and-establishing-of-the-agentic-ai-foundation
- Model Context Protocol. *Specification (2025-11-25)*. 2026年6月閲覧. https://modelcontextprotocol.io/specification/2025-11-25
- Notion. (2025). *Notion's hosted MCP server: an inside look*. 2026年6月閲覧. https://www.notion.com/blog/notions-hosted-mcp-server-an-inside-look
- Notion Developers. (2026). *Connecting to Notion MCP*. 2026年6月閲覧. https://developers.notion.com/guides/mcp/get-started-with-mcp
- makenotion/notion-mcp-server. *Official Notion MCP Server (GitHubリポジトリ)*. 2026年6月閲覧. https://github.com/makenotion/notion-mcp-server
