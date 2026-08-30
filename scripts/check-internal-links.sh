#!/usr/bin/env bash
# 内部リンク検査: 「末尾スラッシュ付き・直接200のみが正常(3xxも異常)」の不変条件を本番に対して検査する。
# 検査ロジックは 2026-08-26 公開記事掲載のワンライナーと同一。
# 記事版との差分は2点のみ:
#   (1) sitemap空のガード(空走査での偽合格を防ぐ)
#   (2) パス妥当性フィルタ — 当該記事自身が公開されており、コードブロック内の
#       ワンライナー文字列(href="/[^"]*" 等)をリンクとして誤抽出するため、
#       シェル記号を含む「パスとして実在しえない」抽出結果だけを除外する。
set -u
SITE="${1:-https://donut-software.com}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# キャッシュ回避クエリ付きで sitemap を取得(デプロイ直後に旧sitemapを引いた実例への対策)
curl -s "$SITE/sitemap-0.xml?v=$(date +%s)" \
  | grep -o '<loc>[^<]*</loc>' | sed 's/<[^>]*>//g' > "$tmp/pages.txt"

if [ ! -s "$tmp/pages.txt" ]; then
  echo "sitemap取得失敗: $SITE/sitemap-0.xml から <loc> を1件も抽出できませんでした" >&2
  exit 1
fi

# 各ページから内部リンク href="/..." を抽出(フラグメント除去・パス妥当性フィルタ・ユニーク化)
while read -r u; do curl -s "$u"; done < "$tmp/pages.txt" \
  | grep -o 'href="/[^"]*"' | sed 's/href="//;s/"$//;s/#.*//' \
  | LC_ALL=C grep -Ev '[][;^ *$(){}<>|\\]' \
  | sort -u > "$tmp/internal.txt"

total=0; ok=0; bad=0
while read -r p; do
  [ -z "$p" ] && continue
  code=$(curl -s -o /dev/null -w '%{http_code}' "$SITE$p")
  total=$((total+1))
  if [ "$code" = "200" ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "$code $p"; fi
done < "$tmp/internal.txt"

echo "ユニーク内部リンク: $total / 直接200: $ok / 異常: $bad"
[ "$bad" -eq 0 ]
