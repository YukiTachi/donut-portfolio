# Donut Portfolio - Claude Code ガイド

## プロジェクト概要

Yuki Tachi の個人ポートフォリオサイト + ブログシステム

- **サイト**: https://donut-software.com
- **フレームワーク**: Astro v5.16.8
- **CMS**: Decap CMS
- **デプロイ**: GitHub Actions → FreeBSD 15.0
- **スタイル**: ダークテーマ、ターミナル風デザイン

---

## 技術スタック

### フロントエンド
- Astro 5.16.8（SSG）
- TypeScript
- CSS（カスタム、変数ベース）
- JetBrains Mono フォント

### コンテンツ管理
- Astro Content Collections（ブログ記事）
- Decap CMS（ブラウザ編集）
- Markdown（記事フォーマット）

### インフラ
- FreeBSD 15.0（本番サーバー）
- Nginx + SSL/TLS
- GitHub Actions（CI/CD）
- Netlify（認証のみ）

---

## ディレクトリ構造
```
donut-portfolio/
├── src/
│   ├── pages/
│   │   ├── index.astro           # トップページ
│   │   └── blog/
│   │       ├── index.astro       # ブログ一覧
│   │       └── [...slug].astro   # 個別記事
│   ├── layouts/
│   │   └── Layout.astro          # 共通レイアウト
│   └── content/
│       ├── config.ts             # コンテンツコレクション設定
│       └── blog/                 # ブログ記事（Markdown）
├── public/
│   ├── admin/                    # Decap CMS管理画面
│   │   ├── config.yml
│   │   └── index.html
│   ├── blog-images/              # ブログ画像
│   └── profile.jpg               # プロフィール写真
└── .github/
    └── workflows/
        └── deploy.yml            # 自動デプロイ設定
```

---

## デザインシステム

### カラーパレット
```css
--color-primary: #0a0e27;      /* 濃紺（背景） */
--color-secondary: #1a1f3a;    /* 濃紺2（カード背景） */
--color-accent: #00d9ff;       /* シアン（アクセント） */
--color-accent-2: #0066ff;     /* 青（サブアクセント） */
--color-text: #e4e4e7;         /* 白系（本文） */
--color-text-light: #a1a1aa;   /* グレー（補足） */
--color-bg: #0f1419;           /* 黒系（ページ背景） */
--color-bg-alt: #161b22;       /* 黒系2（セクション背景） */
--color-border: #30363d;       /* グレー（境界線） */
```

### フォント

- 本文: Inter, -apple-system, BlinkMacSystemFont
- コード: JetBrains Mono, Courier New, monospace

### デザイン原則

1. **ターミナル風UI**: コードブロック、モノスペースフォント
2. **グリッド背景**: 50px × 50px グリッド（透明度 0.4）
3. **スキャンライン**: CRT風エフェクト
4. **ホバーエフェクト**: transform + box-shadow
5. **グラデーション**: タイトルにグラデーション適用

---

## コーディング規約

### Astro コンポーネント
```astro
---
// 1. インポート（外部ライブラリ → ローカル）
import { getCollection } from 'astro:content';
import Layout from '../layouts/Layout.astro';

// 2. データ取得・処理
const data = await getData();

// 3. 型定義（必要に応じて）
interface Props {
  title: string;
}
---

<!-- 4. HTML（セマンティック） -->
<Layout>
  <main>
    <section>
      <!-- コンテンツ -->
    </section>
  </main>
</Layout>

<!-- 5. スタイル（scoped） -->
<style>
  /* BEM的な命名 */
  .section-name { }
  .section-name__element { }
</style>
```

### CSS

- **変数**: CSS変数を活用（`:root`）
- **レスポンシブ**: モバイルファースト
- **単位**: rem優先（フォントサイズ、スペーシング）
- **命名**: 明確で説明的な名前

### TypeScript

- **型安全**: any を避ける
- **インターフェース**: データ構造を明示
- **null チェック**: optional chaining `?.` を活用

---

## ブログ記事のフォーマット

### フロントマター
```yaml
---
title: 記事タイトル
description: 記事の説明文（100文字程度）
pubDate: 2026-01-19T00:00:00.000Z
author: Yuki Tachi
tags:
  - タグ1
  - タグ2
image: /blog-images/image.jpg  # オプション
draft: false                   # true で下書き
---
```

### Markdown本文

- 見出し: `##` から開始（`#` はタイトルで使用済み）
- コードブロック: 言語を指定
- 画像: `/blog-images/` に配置

---

## 開発ワークフロー

### ローカル開発
```bash
# 依存関係インストール
npm install

# 開発サーバー起動
npm run dev
# → http://localhost:4321

# ビルド
npm run build

# プレビュー
npm run preview
```

### デプロイ
```bash
# 変更をコミット
git add .
git commit -m "Update: 変更内容"

# プッシュ（自動デプロイ）
git push origin main

# GitHub Actions が自動実行
# 約2-3分で https://donut-software.com に反映
```

### ブログ記事追加

**方法1: Decap CMS（推奨）**
1. https://donut-software.com/admin/ にアクセス
2. ログイン
3. New Blog → 記事作成 → Publish

**方法2: 直接ファイル作成**
1. `src/content/blog/YYYY-MM-DD-slug.md` 作成
2. フロントマター + 本文を記述
3. git commit & push

---

## よくある修正パターン

### 1. トップページのコンテンツ修正
```
ファイル: src/pages/index.astro
場所: HTML部分（セクションごと）
注意: スタイルは <style> タグ内
```

### 2. 色の変更
```css
/* src/pages/index.astro または該当ファイルの <style> 内 */
:root {
  --color-accent: #00d9ff;  /* ← 変更 */
}
```

### 3. ブログ一覧のレイアウト変更
```
ファイル: src/pages/blog/index.astro
グリッド: .posts-grid のCSS
カード: .post-card のCSS
```

### 4. 個別記事のスタイル変更
```
ファイル: src/pages/blog/[...slug].astro
本文スタイル: .post-content :global() 内
```

---

## 注意事項

### やってはいけないこと

❌ `public/` ディレクトリのファイルをビルド時に参照
❌ 絶対パス `/src/...` での参照
❌ グローバルCSSの乱用
❌ ビルド済みファイル（`dist/`）の手動編集

### やるべきこと

✅ `import` での相対パス参照
✅ CSS変数の活用
✅ セマンティックHTML
✅ アクセシビリティ対応（alt, aria-label など）
✅ レスポンシブデザイン

---

## パフォーマンス

### 画像最適化
```bash
# ImageMagick で圧縮
magick input.jpg -resize 800x800\> -quality 85 output.jpg
```

### ビルド最適化

- Astro は自動的に最適化
- 画像は適切なサイズにリサイズ
- 不要なJSは削除される（SSG）

---

## トラブルシューティング

### ビルドエラー
```bash
# 依存関係を再インストール
rm -rf node_modules package-lock.json
npm install

# キャッシュクリア
npm run build -- --force
```

### デプロイ失敗

1. GitHub Actions のログ確認
2. FreeBSD サーバーのログ確認: `/var/log/nginx/error.log`
3. 手動デプロイテスト: `npm run build`

### Decap CMS ログインできない

1. Netlify Identity が有効か確認
2. Git Gateway が有効か確認
3. 招待メールのリンクを再送

---

## 参考リンク

- [Astro ドキュメント](https://docs.astro.build/)
- [Decap CMS ドキュメント](https://decapcms.org/docs/)
- [Netlify Identity](https://docs.netlify.com/security/secure-access-to-sites/identity/)

---

## 連絡先

質問や提案があれば:
- Email: yuki.tachi@donut-service.com
- GitHub: https://github.com/YukiTachi/donut-portfolio

---

**最終更新**: 2026-01-19
