---
title: NutriSearch 本番リリースまでの道のり――Next.js 16 × NextAuth.js v5 × Stripe ×
  WinterCMS で作る栄養検索サービス
description: 個人開発サービス NutriSearch の本番リリースを振り返ります。Next.js 16 App
  Router・NextAuth.js v5 による Google OAuth 認証・Stripe サブスクリプション・WinterCMS との API
  連携・PM2 + Nginx による本番デプロイまで、技術的な意思決定と詰まったポイントを解説します。
pubDate: 2026-02-23T08:44:00.000+09:00
author: Yuki Tachi
tags:
  - 個人開発
  - Next.js
  - Google OAuth
  - Stripe
  - WinterCMS
  - PM2
  - nginx
image: /blog-images/2026-02-23-8.48の画像.png
draft: false
---
# NutriSearch 本番リリースまでの道のり――Next.js 16 × NextAuth.js v5 × Stripe × WinterCMS で作る栄養検索サービス

**公開日：2026年2月**  
**著者：Yuki（Donut Service）**

---

## はじめに

2026 年 2 月、個人開発サービス **[NutriSearch](https://nutrisearch.donut-service.com/)**（栄養成分検索・計算 Web アプリ）の本番環境を正式に立ち上げました。

NutriSearch は、文部科学省が公開する「[日本食品標準成分表（八訂）増補 2023 年](https://www.mext.go.jp/a_menu/syokuhinseibun/mext_00001.html)」のデータをベースに、食品の栄養成分をすばやく検索・計算できるサービスです。将来的には自社の認知健康プラットフォーム BrainSync と連携し、ソフトウェアエンジニアのパフォーマンス管理にも活用する構想があります。

本記事では、構想からリリースまでに採用した技術スタック、アーキテクチャ上の意思決定、そして開発中に実際に詰まった問題と解決策を振り返ります。

---

## 開発期間と規模

1人での開発で、バックエンド（WinterCMS プラグイン）から着手し、フロントエンドの実装へと進めました。

| | フロントエンド（Next.js） | バックエンド（WinterCMS） |
|---|---|---|
| 言語 | TypeScript | PHP |
| 最初のコミット | 2026/1/18 | 2025/12/20 |
| 最新コミット | 2026/2/22 | 2026/2/16 |
| ファイル数 | 68 ファイル | 72 ファイル |
| コード量 | 5,455 行 | 5,108 行 |

※コード量はコメント・空行を除いた実コード行数。

バックエンドの開発開始から本番リリースまで約 2 ヶ月、フロントエンドは約 5 週間という期間でした。いずれも本業の合間に 1 日 1 時間程度の隙間時間を積み重ねての開発です。それでもフロントエンド・バックエンドそれぞれ 5,000 行超という規模を 1 人で完結させられたのは、AI 支援開発（Cursor・Claude Code）を積極的に取り入れたことが大きく寄与しています。

---

## サービス概要

| 項目 | 内容 |
|------|------|
| 機能（無料） | 食品名・栄養成分の全文検索 |
| 機能（プレミアム） | お気に入り保存・栄養価計算・CSV エクスポート |
| 月額料金 | ¥2,980（税込） |
| ターゲットユーザー | 栄養士・健康意識の高いエンジニア |
| データソース | [日本食品標準成分表（八訂）増補 2023 年](https://www.mext.go.jp/a_menu/syokuhinseibun/mext_00001.html) |

---

## 技術スタック

### フロントエンド

| 技術 | バージョン | 採用理由 |
|------|----------|---------|
| Next.js | 16.1.3 | App Router による柔軟なルーティングと SSR/SSG の使い分け |
| React | 19.2.3 | React Compiler による自動最適化 |
| TypeScript | 5+ | 型安全性の確保 |
| Tailwind CSS | 4+ | ユーティリティファーストで高速な UI 構築 |
| Zustand | 最新 | 軽量なグローバル状態管理 |
| TanStack Query | 最新 | サーバー状態の非同期管理・キャッシュ |

### 認証・決済

| 技術 | 用途 |
|------|------|
| NextAuth.js v5 | Google OAuth 2.0 によるソーシャルログイン |
| Stripe | サブスクリプション課金・Webhook 連携 |

### バックエンド・インフラ

| 技術 | 用途 |
|------|------|
| WinterCMS | 栄養データ API サーバー（既存 VPS 上で稼働） |
| PM2 | Node.js プロセス管理・自動再起動 |
| Nginx | リバースプロキシ・SSL 終端 |
| Let's Encrypt | SSL 証明書の自動更新 |

---

## アーキテクチャ概要

```
[ブラウザ]
    │
    ▼
[Nginx / SSL]  ← Let's Encrypt
    │
    ▼
[Next.js App（PM2 管理）]
    ├── App Router（/app ディレクトリ）
    ├── /api/auth/[...nextauth]  ← NextAuth.js v5
    ├── /api/stripe/checkout     ← Stripe セッション発行
    ├── /api/stripe/webhook      ← Stripe イベント受信
    └── /api/user/               ← サブスクリプション状態・お気に入り
         │
         ├── [Google OAuth]      ← 認証
         ├── [Stripe API]        ← 決済
         └── [WinterCMS API]     ← 栄養データ（既存 VPS）
```

フロントエンドは Vercel や Netlify などのホスティングサービスを利用するのが一般的ですが、今回は既存の VPS で WinterCMS が稼働していたため、**同一サーバー上に PM2 + Nginx** で Next.js をホストする構成を採用しました。インフラコストを抑えつつ、CMS との内部通信レイテンシを最小化できるメリットがあります。

## 認証：NextAuth.js v5 × Google OAuth

### 設計方針

認証には NextAuth.js v5（現 Auth.js）を採用しました。ユーザーにとってパスワード管理の手間がなく、Google アカウントさえあればすぐ使えるソーシャルログインに絞ることで、摩擦を最小化しています。

v5 は v4 と比べて設定ファイルの書き方が大きく変わっており、`auth.ts` をルート直下に置き、`handlers`・`signIn`・`signOut`・`auth` をエクスポートするスタイルになっています。

```typescript
// auth.ts
import NextAuth from "next-auth";
import Google from "next-auth/providers/google";

export const { handlers, signIn, signOut, auth } = NextAuth({
  providers: [
    Google({
      clientId: process.env.GOOGLE_CLIENT_ID!,
      clientSecret: process.env.GOOGLE_CLIENT_SECRET!,
    }),
  ],
  callbacks: {
    async session({ session, token }) {
      // サブスクリプション状態をセッションに付与
      session.user.isPremium = token.isPremium as boolean;
      return session;
    },
  },
});
```

### 対処が必要だった点：本番環境での NEXTAUTH_URL と trustHost 設定

ローカルでは `http://localhost:5000` で動作していたコールバック URL が、本番ドメイン（`https://nutrisearch.donut-service.com`）では認証エラーになるケースが発生しました。原因は `NEXTAUTH_URL` の設定漏れと、Google Cloud Console の **承認済みリダイレクト URI** の設定不足でした。

本番環境では必ず以下の 2 点を確認する必要があります。

1. `.env.production` に `NEXTAUTH_URL=https://nutrisearch.donut-service.com` を設定
2. Google Cloud Console で `https://nutrisearch.donut-service.com/api/auth/callback/google` をリダイレクト URI に追加

さらに、Nginx がリバースプロキシとして HTTPS を終端し、Next.js には HTTP で転送する構成のため、NextAuth.js がリクエストの送信元ホストを信頼できずエラーになる問題も発生しました。`lib/auth/config.ts` に `trustHost: true` を追加することで解決しましたが、この設定が正しく機能するには Nginx 側で以下の 2 行が設定されていることが前提です。

```nginx
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
```

`X-Forwarded-Proto` は `https` をそのまま Next.js に伝えることで、NextAuth.js がコールバック URL を `https://` で正しく組み立てられるようにします。`X-Forwarded-Host` は元のホスト名（`nutrisearch.donut-service.com`）を伝え、リダイレクト URI が正しいドメインで構築されるようにします。この 2 行がない状態で `trustHost: true` だけ設定しても NextAuth.js には不完全な情報しか渡らないため、**Nginx の設定と `trustHost: true` はセットで機能する**点に注意が必要です。

---

## 決済：Stripe サブスクリプション × Webhook

### フロー概要

NutriSearch のプレミアムプランは月額サブスクリプションです。Stripe の Checkout セッションを使い、以下の流れで課金を処理しています。

```
[ユーザーが「プレミアムに登録」をクリック]
    ↓
[Next.js API → Stripe に Checkout セッション発行]
    ↓
[ユーザーが Stripe の決済フォームで支払い]
    ↓
[Stripe → Webhook で NutriSearch に通知]
    ↓
[NutriSearch が WinterCMS のユーザー情報を更新 → プレミアム有効化]
```

### Webhook の実装

Stripe からのイベントを受け取るエンドポイントは `/api/stripe/webhook` に実装しました。受信したリクエストは必ず Stripe の署名を検証してから処理します。

```typescript
// app/api/stripe/webhook/route.ts
import { stripe } from "@/lib/stripe";
import { headers } from "next/headers";

export async function POST(req: Request) {
  const body = await req.text();
  const signature = headers().get("stripe-signature")!;

  let event;
  try {
    event = stripe.webhooks.constructEvent(
      body,
      signature,
      process.env.STRIPE_WEBHOOK_SECRET!
    );
  } catch {
    return new Response("Webhook signature verification failed", { status: 400 });
  }

  switch (event.type) {
    case "checkout.session.completed":
      // プレミアム有効化処理
      break;
    case "customer.subscription.deleted":
      // プレミアム無効化処理
      break;
    case "invoice.payment_failed":
      // 支払い失敗の通知処理
      break;
  }

  return new Response(null, { status: 200 });
}
```

### 対処が必要だった点：テストモードから本番モードへの移行

開発中は Stripe のテストモードキー（`pk_test_...` / `sk_test_...`）を使っていましたが、本番リリース時に本番キー（`pk_live_...` / `sk_live_...`）へ切り替える際にいくつか注意点がありました。

- **価格 ID（`price_...`）はテスト・本番で別物**：テスト環境で作成した価格プランは本番に引き継がれないため、本番の Stripe ダッシュボードで改めて商品と価格を作成し直す必要があります
- **Webhook シークレットも本番用を再取得**：本番環境のエンドポイント（`https://nutrisearch.donut-service.com/api/stripe/webhook`）を Stripe ダッシュボードに登録し、発行された署名シークレット（`whsec_...`）を `.env.production` に設定します
- **`NEXT_PUBLIC_` プレフィックスに注意**：公開可能キー（publishable key）は `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` としてクライアント側に渡しますが、シークレットキーとシークレットは絶対に `NEXT_PUBLIC_` を付けてはなりません

---

## CMS 連携：WinterCMS API との統合

### WinterCMS を選んだ理由

Kuroco や microCMS のようなクラウド型のヘッドレス CMS サービスも候補に挙がりましたが、今回は **WinterCMS（セルフホスト型）** を選択しました。

最大の理由は、**将来的に MCP（Model Context Protocol）サーバーとして仕立て、AI との API 連携を強化する構想**があったからです。外部クラウドサービスでは API の仕様や制約がサービス側に依存しますが、セルフホストであれば API の設計・拡張を完全にコントロールできます。栄養データを AI エージェントから直接参照・操作できる基盤を見据えると、この自由度は不可欠でした。

加えて、既存サーバーに PHP + MariaDB の環境が整っていたこと、WinterCMS が Laravel ベースで MariaDB との相性が良いこと、オープンソースでデータを自社サーバー内に閉じておけることも選定を後押ししました。

### 役割分担

栄養データ（食品名・成分値）は WinterCMS で管理しており、Next.js からは REST API 経由で取得しています。WinterCMS 側に独自のプラグインを実装し、以下のエンドポイントを提供しています。

| エンドポイント | 用途 |
|--------------|------|
| `GET /api/brainsync/nutrition/search?q={query}` | 食品検索 |
| `GET /api/brainsync/nutrition/food/{id}` | 食品詳細取得 |
| `POST /api/brainsync/nutrition/favorites` | お気に入り保存（プレミアム） |

Next.js の API Routes をプロキシ層として使い、CORS の問題を回避しつつ、CMS の認証情報をクライアントに露出させない設計にしています。

```typescript
// app/api/user/favorites/route.ts
export async function GET(req: Request) {
  const session = await auth();
  if (!session?.user?.isPremium) {
    return new Response("Unauthorized", { status: 401 });
  }

  const res = await fetch(`${process.env.NEXT_PUBLIC_API_BASE_URL}/favorites`, {
    headers: {
      Authorization: `Bearer ${process.env.CMS_API_TOKEN}`,
    },
  });
  return new Response(await res.text(), { status: res.status });
}
```

### 対処が必要だった点：本番環境での CORS エラー

ローカル開発時は `http://localhost:8080` でアクセスしていた CMS API が、本番では `https://cms.donut-service.com` となるため、WinterCMS 側の CORS 設定を本番ドメインに合わせて更新する必要がありました。また、WinterCMS が生成する OAuth 2.0 トークンの有効期限管理も、プロキシ層でリフレッシュ処理を追加することで解決しました。

---

## 本番デプロイ：PM2 + Nginx 構成

### PM2 設定

```javascript
// ecosystem.config.js
module.exports = {
  apps: [{
    name: "nutrisearch",
    script: "npm",
    args: "start",
    cwd: "/home/nutrisearch/apps/nutrition-app",
    env: {
      NODE_ENV: "production",
      PORT: 5000,
    },
  }],
};
```

### Nginx 設定のポイント

Stripe Webhook はリクエストボディをそのまま検証するため、Nginx 側でバッファリングを無効にするか、`proxy_pass` の設定を慎重に行う必要があります。また、SSL の自動更新は Let's Encrypt + Certbot で設定し、90 日ごとの更新をシステムの cron に任せています。

---

## 振り返り：開発中に学んだこと

### よかった点

**React 19 × React Compiler の恩恵**：`useMemo` や `useCallback` を意識せずとも、コンパイラが自動でメモ化の最適化を行うため、コードがシンプルに保てました。Next.js 16 との組み合わせは、まだリリース直後の構成ですが安定して動作しています。

**型安全な一気通貫開発**：TypeScript で WinterCMS の API レスポンス型・Stripe のイベント型・NextAuth のセッション型を定義しておくことで、バグの早期発見とリファクタリングのしやすさが大幅に向上しました。

### 苦労した点

**テスト→本番のキー管理**：Stripe・Google OAuth・NextAuth のシークレットがそれぞれ「テスト用」と「本番用」に分かれており、環境変数の管理が煩雑になりました。`.env.production`（本番用・gitignore 済み）と `.env.example`（テンプレート）を分けて管理する運用で解決しています。

**PM2 での環境変数の定義分け**：`ecosystem.config.js` と `.env.production` はどちらも gitignore 済みで機密情報を扱いますが、役割で明確に分けています。この構成になった背景には、**Next.js と PM2 それぞれのツールが環境変数を読み込むタイミングの違い**があります。Next.js は `NODE_ENV=production` の環境では `.env.production` を自動的に読み込む仕様があるため、ビルド時・起動時に Next.js 側が必要とする定数（Stripe のキーや NextAuth のシークレットなど）はここに置けば自然に解決されます。一方、PM2 は Next.js の `.env.*` 読み込みルールとは無関係に動くため、PM2 自身が管理する起動パラメータ（`PORT` や `NODE_ENV` など）は `ecosystem.config.js` の `env` ブロックで明示的に渡す必要があります。つまり「それぞれのツールが期待する場所に定数を置いた結果、自然とこの構成に落ち着いた」というのが実態です。

**Webhook のローカルデバッグ**：Stripe CLI の `stripe listen --forward-to localhost:5000/api/stripe/webhook` を使ったローカルフォワーディングが非常に便利でした。本番に上げる前にイベント処理を十分に検証できたのは大きかったです。

---

## 今後の展望

NutriSearch はまだ MVP 段階であり、以下のロードマップで機能を拡張していく予定です。

**短期（〜3ヶ月）**
- 業務別モードの追加（病院・学校給食・高齢者施設向けの表示切り替え）
- 栄養バランスのビジュアライゼーション強化

**中期（〜6ヶ月）**
- BrainSync プラットフォームとの統合（認知健康スコアと食事の相関分析）
- Cloudflare Zero Trust への認証基盤移行の検討

**長期**
- API の外部公開（栄養計算 API として他社サービスへの提供）
- モバイルアプリ展開（Flutter ベース）

---

## おわりに

NutriSearch は「個人が 1 人で設計・実装・インフラ管理まで完結させる」ことを前提にした開発でした。Next.js 16 の App Router、NextAuth.js v5、Stripe の Webhook 連携、WinterCMS との API 統合など、複数の外部サービスを組み合わせる部分で多くの学びがありました。

特に**テスト環境と本番環境の境界**——キー管理・リダイレクト URI・Webhook エンドポイント——は、チェックリストを作って一つひとつ確認する習慣が重要だと改めて実感しました。

NutriSearch は現在 [nutrisearch.donut-service.com](https://nutrisearch.donut-service.com/) からアクセスできます。フィードバックやご相談は、お気軽に [Donut Service](https://donut-service.com/) のお問い合わせページよりどうぞ。

---

*Yuki／Donut Service — 川崎市を拠点に、業務系 Web アプリ開発・AIシステム構築を承っています。*
