// ブログの日付の表示用整形。ビルド環境(GitHub Actions は UTC)のタイムゾーンに
// 依存しないよう Asia/Tokyo を明示する。pubDate は JST 06:00 の予約公開が多く、
// 指定しないと UTC の日付(前日 21:00)で表示されてしまう
const fmt = new Intl.DateTimeFormat('ja-JP', {
  timeZone: 'Asia/Tokyo',
  year: 'numeric',
  month: 'long',
  day: 'numeric',
});

export function formatDate(date: Date): string {
  return fmt.format(date);
}
