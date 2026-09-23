import type { CollectionEntry } from 'astro:content';

// ブログ記事の公開判定。getCollection('blog') の全呼び出し箇所はこれを通す
// (個別ページ・一覧・404の最近記事で判定がずれると直URLで読めてしまうため)
export function isPublished(post: CollectionEntry<'blog'>): boolean {
  if (post.data.draft === true) return false;
  // 未来日付(予約公開)の除外は本番ビルドのみ。開発サーバでは予約記事をプレビューできる
  if (import.meta.env.PROD && post.data.pubDate > new Date()) return false;
  return true;
}
