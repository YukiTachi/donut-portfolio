---
title: KUSANAGIにWinter CMSを相乗りさせる――WordPress専用ディストリで別CMSを本番稼働させるまで
description: WordPress高速化ディストリとして知られるKUSANAGIに、LaravelベースのWinter
  CMSを相乗りさせて本番稼働させた記録です。provisionが作るのは「箱」だけであること、Laravel派生CMSのCLI名前空間の違い、そしてSELinux
  enforcing下でstorageが書けず500エラーになる問題を、詰まった順に整理します。500の真因はnginxのログではなくアプリのログにありました。
pubDate: 2026-08-24T19:05:00.000+09:00
author: Yuki Tachi
tags:
  - KUSANAGI
  - Winter CMS
  - SELinux
  - Laravel
  - CentOS Stream 9
draft: true
---

## はじめに

KUSANAGI は WordPress の高速化に特化した実行環境ですが、中身を分解すればチューニング済みの NGINX・PHP-FPM・MariaDB という一般的な LEMP スタックでもあります。ならば WordPress 以外の PHP 製 CMS も相乗りできるのではないか――そう考えて試した記録が本記事です。

題材は Winter CMS(Laravel ベースのオープンソース CMS)で、管理画面と REST API を担わせました。稼働はしましたが、CMS ごとの CLI コマンドの差、SELinux enforcing 下での書き込み権限、Apache 前提と NGINX 前提の取り違え、という3つの壁に当たっています。なお KUSANAGI が公式にプロビジョニング対象としているのは WordPress・Movable Type・Drupal であり(KUSANAGI, 2026a)、本記事は範囲外の自己責任構成です。実ドメイン・実パスは汎用化しています。

## 背景・課題

まず `kusanagi provision` が何を作るのかを公式ドキュメントで確認します。このコマンドは「KUSANAGIでWordPressなどを使用するためのプロファイルを作成」し、「Webサーバーのコンフィグや、ドキュメントルートなどがプロビジョニング(配置)され」ます(KUSANAGI, 2026a)。加えてデータベースと DB ユーザーを新規作成し、`--email` を渡せば Let's Encrypt の証明書まで発行します。

重要なのはオプションの意味づけです。CMS の指定は必須で、`--wp` / `--lamp` / `--fcgi` / `--mt` / `--drupal` から1つを選びます。このうち `--lamp` は「LAMP(Linux+Apache httpd+MariaDB+PHP) もしくは LEMP(Linux+NGINX+MariaDB+PHP)で使用するための設定のみをプロビジョン」すると明記されています(KUSANAGI, 2026a)。一方 `--wp` や `--drupal` では `--wpversion` や `--adminuser` などを渡すと CMS 本体の導入まで行います。つまり**「箱まで作る」オプションと「箱と中身の両方を作る」オプションが混在している**わけです。WordPress 以外を載せるなら前者を選ぶことになります。

`--lamp` が「LAMP もしくは LEMP」と両論併記である点にも注意が要ります。どちらになるかは環境依存で、筆者の環境では `httpd` は inactive、NGINX が active でした。要件照合も先に済ませます。Winter CMS 1.2 は PHP 8.1 以上と MariaDB 10.2 以上などを要求し(Winter CMS, 2026a)、KUSANAGI 側の PHP は `kusanagi php --use php83` で切り替えます(KUSANAGI, 2026c)。

## 本論

### provisionは「箱」を作る――中身は自分で入れる

サブドメインの DNS レコードを先に向けておき、`--lamp` でプロファイルを作ります。

```sh
# 箱だけを作る。CMS本体は入らない
kusanagi provision --lamp \
  --fqdn cms.example.com \
  --email admin@example.com \
  cmsprofile
```

DNS が解決していないと Let's Encrypt の検証が通らないため、反映を待ってから実行します。完了後は空のドキュメントルート・Web サーバ設定・DB・証明書が揃うので、あとは Composer で Winter CMS を展開し、`.env` に provision が作った DB 名・ユーザー・パスワードを書けば中身も入ります。なお証明書の自動更新には別の設計問題があり、[以前の記事](/blog/2026-08-02-lets-encrypt証明書のトラブルシュート実践メール証明書エラー1件から自動更新の設計不備を洗い出す)で詳述しました。

### Laravel派生はLaravelと同じではない

最初に手が滑ったのがここでした。Laravel の癖で `php artisan storage:link` を叩くと `There are no commands defined in the "storage" namespace.` が返ります。Winter CMS は Laravel 9 を基盤としていますが(Winter CMS, 2026a)、コンソールコマンドは `winter:` / `plugin:` / `theme:` などの独自の名前空間で構成されています(Winter CMS, 2026c)。`storage:link` に相当するものはなく、公開ファイルをシンボリックリンクで複製する `winter:mirror` がその役割を担います。マイグレーションも同様で、公式は「The `winter:up` (or `migrate`) command will perform a database migration」と記しています(Winter CMS, 2026b)。`migrate` はエイリアスとして生きている一方、筆者が推測した `winter:migrate` は存在しません。

```sh
php artisan winter:up                    # migrate はエイリアス
php artisan winter:mirror public --relative
```

**「Laravel 派生だからコマンドも同じ」という推測は成り立たない**。`php artisan list` を眺めれば済む話でした。

### 500エラーの真因はアプリのログにある

管理画面にアクセスすると 500 が返ります。反射的に NGINX のエラーログを見たのですが、並んでいたのは静的ファイルの 404 ばかりで、ここで真因を見誤りました。アプリ側のログ(`storage/logs/`)に切り替えると、原因は一行で出ていました。

```
file_put_contents(/path/to/app/storage/framework/cache/...):
Failed to open stream: Permission denied
```

Laravel 公式は「Laravel will need to write to the `bootstrap/cache` and `storage` directories」と述べています(Laravel, 2026)。ところが所有者と mode に異常はありません。

`ls -Z` で SELinux コンテキストを見ると、`storage` 配下はホーム既定の `user_home_t` のままでした。SELinux のポリシーでは `/usr/bin/nginx` と `/usr/bin/php-fpm` がいずれも `httpd_t` ドメインのエントリポイントとして定義されており、httpd から読み書きさせたいファイルには `httpd_sys_rw_content_t` を付けるのが定石です(SELinux Project, 2026a)。NGINX も PHP-FPM も httpd ポリシーで拘束される側だ、ということです。

```sh
ls -Zd storage bootstrap/cache                                     # まず現状を読む
chcon -R -t httpd_sys_rw_content_t storage bootstrap/cache         # 切り分け(一時的)
semanage fcontext -a -t httpd_sys_rw_content_t "/path/to/app/storage(/.*)?"
restorecon -R -v /path/to/app/storage                              # 恒久化
```

`chcon` はファイルのコンテキストを書き換えるだけで(GNU coreutils, 2026)、ポリシー側の定義には何も残りません。対して `semanage fcontext` は「the default file system labeling on an SELinux system」を管理し(SELinux Project, 2026b)、`restorecon` はその指定どおりに既定コンテキストを復元します(SELinux Project, 2026c)。`chcon` だけでは再ラベル時に元へ戻る、ということです。

以前 [CentOS Stream 9 でメールサーバーを建てた記事](/blog/2026-08-16-centos-stream-9でメールサーバーを建てるselinuxを切らずにmail-tester-10-10へ)ではソケット接続の拒否を audit2allow で通しましたが、今回はラベルを直すだけで済みます。**問題の層が違えば打ち手も違う**わけです。

### 404とApache前提――残り2つの取り違え

500 が解けた後も管理画面の見た目は崩れていました。テーマ由来の静的ファイル(jQuery や Bootstrap)が 404 だったのです。ただし今回はフロントエンドを別アプリが担当するため、デモテーマの依存は不要でした。

再起動にも罠があり、`systemctl restart httpd` は空振りします。KUSANAGI では専用コマンドを使い、`kusanagi nginx` がオプションなしで NGINX を再起動します。`--use` で指定するバージョンも `nginx131` / `nginx130` / `nginx129` とバージョン番号込みの名前です(KUSANAGI, 2026b)。サービス名がバージョンに紐づく設計は、certbot の deploy hook への直書きが NGINX 更新で置き去りになるという前述の記事の論点と地続きです。

## 実践への応用

今回の作業から一般化できることを3つ挙げます。

第1に、**プロビジョナが作る範囲を先に確定させる**。この差はドキュメントに明記されているので、着手前に数分読めば「provision したのに何も出ない」を丸ごと回避できます。想定外の使い方をするときほど、公式が何を保証しているかの確認が効きました。

第2に、**Permission denied は二層で疑う**。UNIX パーミッションと SELinux コンテキストは症状が完全に同じです。所有者と mode に異常がなければ次は必ず `ls -Z` を見る。この順序を型にしておけば、SELinux を無効化して逃げる必要はありません。前回のメールサーバー構築との対比から、その型は有効だと考えています。

第3に、**Web サーバのログは、Web サーバが知っていることしか書かない**。アプリが投げた例外の詳細は、アプリのログにしか残らないことがあります。

限界も明記しておきます。この構成は公式サポート範囲外であり、`kusanagi upgrade` 系の操作や将来の更新がこれをどこまで壊さないかは保証されていません。筆者はまだ長期運用の実績を持たず、この点はデータのない推測にとどまります。

## まとめ

- `kusanagi provision` の `--lamp` は「設定のみ」で CMS 本体は入らない(KUSANAGI, 2026a)
- Winter CMS の CLI は Laravel と別物。`winter:up`(`migrate` はエイリアス)と `winter:mirror` を使う(Winter CMS, 2026b, 2026c)
- NGINX も PHP-FPM も `httpd_t` で動くため、`storage` には `httpd_sys_rw_content_t` が要る(SELinux Project, 2026a)
- 切り分けは `chcon`、恒久化は `semanage fcontext` + `restorecon`(SELinux Project, 2026b, 2026c)
- 再起動は `systemctl restart httpd` ではなく `kusanagi nginx`(KUSANAGI, 2026b)

KUSANAGI は「WordPress 専用ツール」ではなく「汎用 LEMP スタック + プロビジョナ」として捉え直せます。次は運用更新を一度通し、この構成がアップグレードに耐えるかを確かめるつもりです。

## 参考文献

本記事は技術テーマのため学術論文は参照せず、公式ドキュメントおよび man ページ(一次資料)に基づいています。

### 公式ドキュメント

- GNU coreutils. (2026). *chcon(1)*. Linux manual page. 2026年8月閲覧. https://man7.org/linux/man-pages/man1/chcon.1.html
- KUSANAGI. (2026a). *provision*(KUSANAGI コマンド). GMO Prime Strategy. 2026年8月閲覧. https://kusanagi.tokyo/document/commands/provision/
- KUSANAGI. (2026b). *nginx*(KUSANAGI コマンド). GMO Prime Strategy. 2026年8月閲覧. https://kusanagi.tokyo/document/commands/nginx/
- KUSANAGI. (2026c). *php*(KUSANAGI コマンド). GMO Prime Strategy. 2026年8月閲覧. https://kusanagi.tokyo/document/commands/php/
- Laravel. (2026). *Deployment: Directory Permissions*. Laravel 12.x Documentation. 2026年8月閲覧. https://laravel.com/docs/12.x/deployment
- SELinux Project. (2026a). *httpd_selinux(8)*(selinux-policy-doc). Manual page. 2026年8月閲覧. https://www.mankier.com/8/httpd_selinux
- SELinux Project. (2026b). *semanage-fcontext(8)*(policycoreutils-python-utils). Manual page. 2026年8月閲覧. https://www.mankier.com/8/semanage-fcontext
- SELinux Project. (2026c). *restorecon(8)*(policycoreutils). Manual page. 2026年8月閲覧. https://www.mankier.com/8/restorecon
- Winter CMS. (2026a). *Getting Started: Installation*. Winter CMS v1.2 Documentation. 2026年8月閲覧. https://wintercms.com/docs/v1.2/docs/setup/installation
- Winter CMS. (2026b). *Setup & Maintenance Commands*. Winter CMS v1.2 Documentation. 2026年8月閲覧. https://wintercms.com/docs/v1.2/docs/console/setup-maintenance
- Winter CMS. (2026c). *Command Line Interface*. Winter CMS v1.2 Documentation. 2026年8月閲覧. https://wintercms.com/docs/v1.2/docs/console/introduction
