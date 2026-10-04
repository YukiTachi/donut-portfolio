---
title: 証明書更新の再起動でnginxが起動できなくなった――Tailscale Serveと443番ポートの早い者勝ち
description: KUSANAGIの本番VPSでnginxが夜中に止まり、サイトが朝まで落ちていました。原因はnginxの異常終了ではなく、certbotのpost-hookによるrestartの一瞬の隙にtailscale serveが443番を取り、新しいnginxがbindできずに起動失敗したことでした。揮発ジャーナルで消えたログの再構成、「停止」と「起動失敗」の読み分け、ポートの分離とRestart=on-failureによる対策までを実録で整理します。
pubDate: 2026-10-05T03:00:00.000+09:00
author: Yuki Tachi
tags:
  - nginx
  - Tailscale
  - certbot
  - systemd
  - KUSANAGI
  - トラブルシューティング
draft: true
---

## はじめに

2026年10月4日の朝、本番VPS（CentOS Stream 9、KUSANAGI）上のWebサイトが応答しなくなっていました。nginxのプロセスがありません。

調べてみると、nginxは「落ちた」のではありませんでした。証明書更新後の再起動で一度止まり、その直後の起動に失敗していたのです。起動を妨げたのは、同じホストで動くTailscale Serve（tailnet内にサービスを公開する機能）でした。

本記事では、夜中のログが消えた状態からの再構成、「停止」と「起動失敗」の読み分け、同じポートを狙う2つのデーモンが早い者勝ちになる構造、そして対策を順に扱います。ドメイン・tailnet名・IPアドレス・内部ポートは汎用化しています。

## 背景・課題

構成は次のとおりです。

- nginx（KUSANAGIのバージョン付きサービス名 `nginx131`）が80/443番で全アドレスを待ち受ける
- 同じホストで `tailscale serve` が運用用の管理画面をtailnet内にHTTPSで公開する
- KUSANAGIの証明書更新を週次のcronで実行し、certbotに `--post-hook 'systemctl restart nginx131'` が渡される

最初の見立ては間違っていました。別サーバで動く夜間ジョブがこのサーバに接続できずに失敗していたので、「3時より前に何か起きた」と考えたのです。実際の停止は03:13で、ジョブがこのサーバに接続したのは処理の終盤でした。ジョブの開始時刻と接続時刻を混同していたことになります。

もう1つの障害はログでした。パネルから再起動した後に `journalctl` を見ても、夜中の記録がありません。`/var/log/journal` が存在せず、ジャーナルは `/run/log/journal`（メモリ上）にしか書かれていなかったためです。journaldの `Storage=auto` は、`/var/log/journal` が存在すれば永続、無ければ揮発になります（systemd project, 2026b）。

## 本論

### 残っていたログで夜を再構成する

ジャーナルは消えても、rsyslogが書く `/var/log/messages` は残っていました。ただ、毎分のcronセッションが出す `Reached target Shutdown` などの定型行でgrepの結果が埋まり、除外パターンを何段階か足してようやく読める量になりました。

そのうえで容疑者を1つずつ外しました。nginxパッケージの更新は6月で無関係、dnfの自動更新は無し、00:00のlogrotateは正常終了でpostrotateもUSR1（ログの開き直し）を送るだけです（nginx, 2026a）。毎分の記録が途切れず続いていたので、OSは一晩中生きていました。

### 決定的な数秒

`/var/log/messages` と `/var/log/letsencrypt/letsencrypt.log` を時刻で突き合わせると、次の流れになりました（要点を整形した抜粋）。

```text
03:12     certbot: 複数の証明書を更新（証明書ごとに deploy-hook）
03:13:11  certbot: post-hook 'systemctl restart nginx131' を実行
03:13:13  tailscaled: listening on [<tailnetのIPv6>]:443
03:13:13  nginx: bind() to [::]:443 failed (98: Address already in use)
```

restartでnginxが止まり、新しいnginxが起動するまでの2秒ほどの間に、tailscaledが443番を取っています。certbotもpost-hookの失敗を記録していましたが、それ以上は誰も何もしません。

post-hookは更新を試みたときだけ実行され、同じhookは複数の証明書にまたがって1回にまとめられます（Certbot, 2026）。更新対象になるのは残り期間が短くなった証明書だけです。Certbot 4.0以降の既定は「寿命の1/3未満」、それ以前は30日前で、90日証明書ならどちらも約30日前です（Certbot, 2026）。週次の更新処理でも再起動が起きるのは更新があった回だけで、これが今まで表に出なかった理由だと考えています。

### なぜ [::]:443 だけ失敗したのか

`tailscale serve` はtailnetのIPアドレスで待ち受けます（Tailscale, 2026）。普段はnginxがワイルドカード（`0.0.0.0` と `[::]`）で443番を握っているので、tailscaledは取れません。Linuxの `socket(7)` には、ワイルドカードで待ち受けているポートには、どのローカルアドレスでもbindできないと書かれています（Kerrisk, 2026）。

逆方向、つまり特定アドレスで待ち受け中のポートへのワイルドカードbindも、今回のログが示すとおり `EADDRINUSE`（エラー番号98）になりました。nginxはIPv6の `[::]` を既定で `ipv6only=on` として開くので、IPv4とIPv6は別々のソケットです（nginx, 2026b）。tailscaledはIPv6側だけを先に取り、IPv4側を取ったのは34秒後でした。

tailscaledがポート使用中のときに再試行するかどうかは、公式ドキュメントに記述が見つかりませんでした。「しばらくしてから取れた」のは、ログからの推定です。

朝のパネルからの再起動も、同じ早い者勝ちでした。このときはnginxがたまたま勝ち、今度は管理画面のほうが公開できなくなっていました。同じ構成のまま再起動を繰り返しても、どちらが勝つかは決まりません。

### 対策

**① Tailscale Serveを443から外す（根本対策）**。待ち受けポートを8443に移しました。

```sh
tailscale serve reset
tailscale serve --bg --https=8443 http://127.0.0.1:<内部ポート>
ss -ltnp | grep ':443 '   # 443 が nginx だけになったことを確認
```

`--bg` を付けた設定は、再起動やTailscaleの再起動後も維持されます（Tailscale, 2026）。

**② nginxにRestart=on-failureを足す（保険）**。drop-inで追加します。

```ini
# /etc/systemd/system/nginx131.service.d/restart.conf
[Service]
Restart=on-failure
RestartSec=10s
```

`on-failure` は非ゼロ終了・異常シグナル・タイムアウトで再起動し、`systemctl stop` や `restart` によるsystemd自身の停止では再起動しません（systemd project, 2026a）。再起動は `StartLimitIntervalSec=`・`StartLimitBurst=` の回数制限を受けるので（systemd project, 2026c）、競合が長く続けば止まります。ただし、今回と同じbind失敗を再現してこの設定の効き方を確かめたわけではありません。

**③ restartをreloadにする案は見送り**。reload（HUP）ならマスタープロセスは待ち受けソケットを持ったまま設定を読み直します（nginx, 2026a）。ただ、このpost-hookはKUSANAGIのコマンドラインから直接certbotに渡されているので、renewal設定ファイルを書き換えても上書きされません（筆者の環境での確認）。

**④ ジャーナルを永続化する**。`/var/log/journal` を作っただけでは足りませんでした。journaldは `journalctl --flush`（またはSIGUSR1）までは揮発ストレージに書き続け、切り替えは通常は起動時に自動で行われます（systemd project, 2026b）。作成直後に `journalctl --flush` を実行し、書き込み先が移ったことを確認しました。

最後に `systemctl restart nginx131` を実行し、443番がnginxだけで占有されたまま問題なく立ち上がることを確認しています。

## 実践への応用・考察

1つ目は、「落ちた」を中身で分けることです。異常終了・ハング・再起動時の起動失敗は、ログ上の見え方も対策も違います。今回の決め手は、停止の直後に起動の試行とbindエラーが並んでいたことでした。順番を確定させる前に原因の仮説を立てると、私のように「3時より前」という思い込みに引きずられます。

2つ目は、同じポートを狙うデーモンの同居です。これは普段は問題として見えません。勝敗が決まるのはrestartや再起動のときだけで、その頻度は証明書更新のように数ヶ月に一度だったりします。TailscaleとKUSANAGIのどちらかが悪いわけではありません。組み合わせたときに初めて生まれる競合です。

3つ目は、定期処理のrestartの設計です。certbotはhookの失敗を記録しますが、直しはしません。「失敗したら誰が直すのか」まで決めておく必要があります。Let's Encryptは証明書の寿命を2027年2月に64日、2028年2月に45日へ短縮する予定です（Let's Encrypt, 2025）。更新の頻度が上がれば、こうした潜在的な競合が表に出る機会も増えると私は見ています。

関連する運用の話として、post-hookとdeploy-hookの使い分けやバージョン付きサービス名の落とし穴は「[Let's Encrypt証明書のトラブルシュート実践](/blog/2026-08-02-lets-encrypt証明書のトラブルシュート実践メール証明書エラー1件から自動更新の設計不備を洗い出す/)」に、同じ本番機の更新作業は「[KUSANAGI本番機の一括更新](/blog/2026-09-01-centos-stream-9のkusanagi本番機を820パッケージ一括更新する完了条件を先に設計する/)」に書きました。

## まとめ

- nginxの停止は異常終了ではなく、certbotのpost-hookによるrestart直後の起動失敗だった
- restartの2秒ほどの隙にtailscale serveが443番（IPv6側）を取り、nginxのbindが `EADDRINUSE` になった
- 同じポートを狙う2つのデーモンは、restartや再起動のたびに勝敗が変わる。Tailscale Serveを8443に移して競合をなくした
- 保険として `Restart=on-failure` を足し、ジャーナルを永続化した（作成後の `journalctl --flush` を忘れない）

同じホストでnginxとTailscale Serveを動かしている方は、`ss -ltnp` で443番を誰が握っているか、一度確認してみてください。

## 参考文献

### 公式ドキュメント

- Certbot (EFF). (2026). *User Guide — Certbot documentation*. 2026年10月閲覧. https://eff-certbot.readthedocs.io/en/stable/using.html
- Kerrisk, M. (2026). *socket(7) — Linux manual page*. 2026年10月閲覧. https://man7.org/linux/man-pages/man7/socket.7.html
- Let's Encrypt. (2025). *Decreasing Certificate Lifetimes to 45 Days*. 2026年10月閲覧. https://letsencrypt.org/2025/12/02/from-90-to-45
- nginx. (2026a). *Controlling nginx*. 2026年10月閲覧. https://nginx.org/en/docs/control.html
- nginx. (2026b). *Module ngx_http_core_module*. 2026年10月閲覧. https://nginx.org/en/docs/http/ngx_http_core_module.html
- systemd project. (2026a). *systemd.service(5)*. 2026年10月閲覧. https://man7.org/linux/man-pages/man5/systemd.service.5.html
- systemd project. (2026b). *journald.conf(5)*. 2026年10月閲覧. https://man7.org/linux/man-pages/man5/journald.conf.5.html
- systemd project. (2026c). *systemd.unit(5)*. 2026年10月閲覧. https://man7.org/linux/man-pages/man5/systemd.unit.5.html
- Tailscale. (2026). *tailscale serve command*. 2026年10月閲覧. https://tailscale.com/kb/1242/tailscale-serve
