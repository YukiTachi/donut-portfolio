# ブログ記事 自動生成タスク(cron 非対話実行)

あなたは cron から **非対話モード(`claude --print`)** で起動された Claude Code です。
ユーザーへの問い返しはできません。判断は自分で行い、最後に**機械可読なサマリーブロック**を必ず出力してください。

## 最初に必ず読むドキュメント

1. `docs/blog-automation.md` — 運用ルール(ネタソース・エビデンス・引用・記事構成・チェックリスト・Git/Notion 運用)
2. `docs/blog-format.md` — ファイル名・フロントマター・本文フォーマット

この 2 つのルールに**厳密に従う**こと。

## 処理手順

1. **ネタ取得**: Notion MCP で「ブログネタ」ページを取得し、`## 未処理` セクションの**最上行(箇条書き 1 件)**を処理対象として抜き出す。
   - 「未処理」が空なら、何も生成せず `RESULT=SKIP` を出力して終了する(後述のサマリー形式)。
2. **処理中へ移動**: 対象の行を Notion 上で `## 未処理` から `## 処理中` へ移動する。
3. **エビデンス収集**: Web 検索でテーマに応じた論文・一次資料・統計を収集する(`docs/blog-automation.md` のテーマ別エビデンスルールに従う)。
4. **既存トーンの確認**: `src/content/blog/` 内の既存記事を読み、文体・トーンを揃える。
5. **記事生成**: `docs/blog-automation.md` の記事構成テンプレートに従って本文を書く。フロントマターは `docs/blog-format.md` の項目順。**必ず `draft: true`**。
6. **自己レビュー**: `docs/blog-automation.md` の自己チェックリスト**全項目**について、1 項目ずつ内部的に `[OK]` か `[FIX]` を判定する。
   - `[FIX]` が 1 つでもあれば、その項目を修正してから再判定する。**全項目が `[OK]` になるまで保存しない**。
   - 判定の根拠が曖昧な項目(例: 文字数、出典の有無)は、実際に数える・該当箇所を確認するなど客観的に検証する。
7. **保存**: `src/content/blog/YYYY-MM-DD-slug.md` に保存する(日付は JST の本日、slug はタイトル由来)。
8. **Git**: `git add` → `git commit`(メッセージ `chore(blog): auto-draft - {タイトル}`)→ `git push origin main`。
9. **Notion 更新**: 成功なら対象行を `## 処理中` から `## 完了` へ移動し、`- YYYY-MM-DD HH:MM | {タイトル} → /blog/{slug}` を追記する。

## エラー時の扱い

- いずれかの工程で続行不能な失敗が起きたら、可能なら Notion の対象行を `## 処理中` → `## 未処理` に戻し、
  `- {元のネタテキスト} [前回失敗: YYYY-MM-DD, {エラー概要}]` の形式でエラーメモを付ける。
- そのうえで `RESULT=ERROR` のサマリーを出力して終了する。
- `git push` まで成功したが Notion 更新だけ失敗した場合は、記事生成は**成功扱い**とし、`RESULT=SUCCESS` かつ `NOTION=FAILED` を出力する。

## 出力契約(最重要)

処理の最後に、**必ず**以下のマーカーで囲んだサマリーブロックを**標準出力**へ出力すること。
シェルスクリプトがこのブロックだけを抽出してメール通知に使う。各行は `KEY=VALUE` 形式、1 行 1 項目、余計な装飾を付けない。

### 成功時

```
===BLOG_CRON_RESULT_BEGIN===
RESULT=SUCCESS
TITLE={記事タイトル}
FILE={src/content/blog/からのパス}
SLUG={slug}
CHARS={本文の概算文字数}
TAGS={タグをカンマ区切り}
DRAFT=true
TOPIC={元ネタのテキスト}
EVIDENCE_PAPER={学術論文の参照件数}
EVIDENCE_OFFICIAL={公式ドキュメントの件数}
EVIDENCE_GOV={政府・公的資料の件数}
EVIDENCE_WEB={Web記事の件数}
BRANCH=main
COMMIT={コミットハッシュ短縮形}
COMMIT_MSG={コミットメッセージ}
PUSH={OK または FAILED}
NOTION={OK または FAILED}
===BLOG_CRON_RESULT_END===
```

### スキップ時(未処理ネタなし)

```
===BLOG_CRON_RESULT_BEGIN===
RESULT=SKIP
MESSAGE={スキップ理由の簡潔な説明}
===BLOG_CRON_RESULT_END===
```

### 失敗時

```
===BLOG_CRON_RESULT_BEGIN===
RESULT=ERROR
ERROR_PHASE={topic_fetch | paper_search | generation | format_check | git_push | notion_update のいずれか}
ERROR={エラー概要を1行で}
TOPIC={判明していれば元ネタ、不明なら空}
NOTION_RESTORED={OK または FAILED — 対象行を未処理に戻せたか}
===BLOG_CRON_RESULT_END===
```

### 注意

- サマリーブロックは**1 回だけ**、処理の最後に出力する。
- **`git push` が失敗した場合の出力は次に統一する**:
  - 正規形(推奨): `RESULT=ERROR` + `ERROR_PHASE=git_push`(記事はローカルに commit 済みでも push できていない状態)。
  - `RESULT=SUCCESS` + `PUSH=FAILED` でも可(シェル側で失敗扱いに変換される)。迷ったら正規形を使うこと。
- 値に改行を含めない(タイトルやメッセージは 1 行に収める)。タイトルにカンマを含めてよいが、`TAGS` のみカンマ区切りである点に注意。
