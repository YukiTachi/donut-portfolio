---
title: Let's Encrypt証明書のトラブルシュート実践――メール証明書エラー1件から自動更新の設計不備を洗い出す
description: メールクライアントの証明書期限切れ警告から出発して掘り下げると、certbot自動更新の独立した設計不備が3つ見つかりました。①証明書ファイルの更新とプロセスへの反映は別物(deploy hook必須)、②nginxメジャー更新で置き去りになったhook内のサービス名、③「たまたま通っていた」standalone認証。webrootへの移行とnginxのlocation優先順位の罠まで、切り分けの思考プロセスとともに解説します。
pubDate: 2026-08-02T19:00:00.000+09:00
author: Yuki Tachi
tags:
  - Let's Encrypt
  - certbot
  - nginx
  - SSL/TLS
  - トラブルシューティング
draft: true
---

## はじめに

ある日、メールクライアント(Thunderbird)が「この証明書の有効期限が過ぎています」という警告を出しました。ところがサーバで `certbot certificates` を実行すると、該当ドメインの証明書は有効期限内と表示されます。ディスク上の証明書は新しいのに、クライアントには期限切れが見えている――この矛盾が出発点でした。

掘り下げていくと、この1件の警告の裏に、certbot 自動更新の設計不備が3つ埋もれていました。本記事では、症状から根本原因へ切り分けていく過程を実録として辿り、そこから抽出できる教訓を整理します。なお、ドメイン名・ホスト構成・パスはすべて汎用化しています(`example.com` 等)。

## 背景・課題

前提となる環境は次のとおりです。

- Linux サーバ上の nginx(複数の server block で複数ドメインを配信)
- 同一サーバに Dovecot(IMAP)と Postfix(SMTP)が同居し、`mail.example.com` の証明書を使用
- 証明書は Let's Encrypt から certbot で取得し、複数ドメイン分を運用

certbot の自動更新は、タイマーや cron から `certbot renew` を定期実行し、期限が近い証明書だけを更新する仕組みです。各証明書の更新設定は `/etc/letsencrypt/renewal/` 配下の設定ファイルに保存され、認証方式(authenticator)や pre/post/deploy の各 hook もここに記録されます(Certbot, 2026)。

「自動更新は動いているはず」という前提は、今回の調査で三重に裏切られることになります。しかも3つの不備は互いに独立していて、どれか1つを直しても残りは直りません。

## 本論

### 症状①: ファイルは新しいのに、プロセスは古い証明書を返す

まず、クライアントの言い分とディスク上の証明書のどちらが正しいのかを確定させます。稼働中のサーバが実際に返す証明書は `openssl s_client`(SSL/TLSクライアント。OpenSSL, 2026)で確認できます。

```sh
# IMAPS(993番ポート)が実際に返す証明書のシリアルと期限を確認する
openssl s_client -connect mail.example.com:993 </dev/null 2>/dev/null | openssl x509 -noout -serial -dates
```

結果、稼働中の Dovecot が返す証明書は、ディスク上のものとシリアル番号が異なり、有効期限も切れていました。つまり certbot は証明書ファイルを正しく更新していたが、Dovecot/Postfix は起動時に読み込んだ古い証明書をメモリに保持し続けていたわけです。対処は単純で、両サービスの reload(設定再読込。Dovecot では `doveadm reload` に相当します。Dovecot, 2026)で新しい証明書が返るようになりました。

再発防止には deploy hook を使います。certbot は `/etc/letsencrypt/renewal-hooks/deploy/` に置かれた実行可能ファイルを、証明書の更新が成功したときに実行します(Certbot, 2026)。

```sh
#!/bin/sh
# /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh
systemctl reload dovecot postfix
```

1つ目の教訓は、「証明書ファイルの更新」と「プロセスへの反映」は別物、ということです。

### dry-run が掘り当てた別の不発弾

deploy hook を設置したので、動作確認のため `certbot renew --dry-run` を実行しました。dry-run はステージング環境に対して更新処理をテストする機能で、pre/post hook は既定で実行されます(deploy hook は既定では実行されません。Certbot, 2026)。

すると、今回の件とは無関係な複数の証明書が `Could not bind TCP port 80` で失敗し、さらに別の証明書では post-hook が「nginx129.service not found」というエラーを出しました。問題はここで2つに分岐します。

### 問題A: nginxのメジャー更新が hook 内のサービス名を置き去りにする

post-hook のエラーは、renewal 設定ファイル内の `post_hook` が古いサービス名を参照したままだったことが原因です。使用している nginx ディストリビューションはサービス名にバージョン番号を含む形式で、nginx を 1.29 系から 1.31 系へ更新した際にサービス名が変わっていました。一部の renewal 設定だけ手で直され、残りが取り残されていたのです。

```sh
# 対象を確認してから、バックアップ付きで一括置換する
grep -l 'nginx129' /etc/letsencrypt/renewal/*.conf
sed -i.bak 's/nginx129/nginx131/g' /etc/letsencrypt/renewal/*.conf
```

教訓の2つ目です。サービス名を含む参照は、本体の更新に自動では追従しません。hook・cron・監視設定など、横断的に洗い出す必要があります。

### 問題B: 「たまたま通っていた」standalone認証

ポート80のバインド失敗は、より根深い問題でした。失敗した証明書群は `authenticator = standalone`、つまり certbot 自身がポート80で待ち受けて認証する方式です(Certbot, 2026)。nginx が80番を掴んで稼働している以上、原理的に成功しません。しかも該当の renewal 設定には、nginx を止める pre_hook も再開する post_hook も定義されていませんでした。

過去に更新できていたのは、nginx 停止中にたまたま手動更新が通っていただけと推測されます(構成からの推定で、当時の記録はありません)。つまりこの証明書群は、次回の自動更新で確実に失敗する時限爆弾でした。

### standalone から webroot への移行

nginx を止めずに更新するため、認証方式を webroot に切り替えます。webroot は、要求ドメインごとに `${webroot-path}/.well-known/acme-challenge` へ一時ファイルを作成し、既存のWebサーバにそれを配信させる方式です(Certbot, 2026)。移行手順は次のとおりです。

1. 各ホストの server block に acme-challenge 用の location を追加する(後述の罠あり)
2. テストファイルを置いて `curl` で疎通確認する
3. `certbot certonly --webroot -w /var/www/acme -d mail.example.com` で方式を切り替えて再発行する
4. `certbot renew --dry-run` で全証明書の成功を確認する

Web配信を持たないメール専用ホストには、acme-challenge だけを配信する最小の server block を新設しました。なお本番環境での再発行には、同一のドメイン集合に対する発行は7日あたり5回まで(約34時間で1枠回復)というレート制限があります(Let's Encrypt, 2025)。試行錯誤は dry-run(ステージング)側で済ませるべきです。

### nginxのlocation優先順位という落とし穴

手順1で罠を踏みました。location を追加したのに、`curl` が404を返し続けるホストがあったのです。

原因は、既存設定に残っていた中身が空の `location ~* /\.well-known` でした。nginx の location 評価は、①prefix location の最長一致を記憶し、②正規表現 location を記載順に評価して最初のマッチを採用し、③どれもマッチしなければ記憶した prefix を使う、という順序です(nginx, 2026)。あとから足した通常の prefix location は、既存の正規表現 location に横取りされていました。対処は `^~` 修飾子です。最長一致の prefix に `^~` が付いていれば、正規表現は評価されません(nginx, 2026)。

```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/acme;
}
```

もう1つ、server 直下に無条件の `return 301` を持つホストで、「location を足してもリダイレクトが優先されるように見える」件がありました。実はこの診断は一度誤っていて、location は正しく効いていました(別の要因による404を、優先順位の問題と誤読していました)。最終的な切り分けは、アクセスログに当該リクエストが記録されるかの確認と、location 内に一時的に `return 200` を置いた到達確認で確定させました。憶測を重ねるより、nginx 自身に処理経路を吐かせるのが正攻法です。

## 実践への応用・考察

今回の経験から一般化すると、証明書の自動更新の信頼性は「certbot が動いているか」ではなく、次の3点で決まります。

1. 更新後にプロセスへ反映される仕組みがあるか(deploy hook)
2. hook が参照する外部(サービス名等)が現状と一致しているか
3. 全証明書が、稼働構成と両立する認証方式で更新できるか

1件のメール証明書エラーは、この3点すべての不備を露出させました。興味深いのは、3つの不備がどれも「一度は正しく動いていた構成」だったことです。deploy hook の欠如は手動運用の時代には問題にならず、サービス名は更新前までは正しく、standalone は Web サーバと同居する前なら妥当な選択でした。構成は自然に劣化するのではなく、周囲が変わることで相対的に壊れていきます。

定期的な `certbot renew --dry-run` は、この種の腐敗を実際の期限切れより早く発見できる、最も安価な手段です。ただし deploy hook は既定では dry-run で実行されない(Certbot, 2026)ため、反映側の検証には `openssl s_client` での実測を組み合わせるのが確実です。

## まとめ

- 証明書ファイルの更新とプロセスへの反映は別物。deploy hook で reload を自動化し、実際に返される証明書を `openssl s_client` で確認する。
- nginx のメジャー更新は renewal 設定内のサービス名を置き去りにする。hook・cron・監視など横断的な参照を、更新時にまとめて洗う。
- standalone 認証は Web サーバと同居した時点で「たまたま通る」構成になる。webroot へ移行し、`renew --dry-run` で全件成功を確認する。
- nginx の location は「`^~` 付き prefix > 正規表現 > 通常 prefix」の優先順位。効かないときは憶測せず、アクセスログと一時的な `return 200` で到達を実測する。

本ブログでは記事の自動生成や出典検証など「自動化と、その検証」を繰り返し扱ってきましたが、証明書の自動更新も同じです。「動かした」で終わらせず「壊れたら気づける」ところまで作って、初めて自動化と呼べるのだと思います。

## 参考文献

### 公式ドキュメント

- Certbot (EFF). (2026). *User Guide — Certbot documentation*. 2026年8月閲覧. https://eff-certbot.readthedocs.io/en/stable/using.html
- Dovecot. (2026). *Doveadm — Dovecot CE documentation*. 2026年8月閲覧. https://doc.dovecot.org/main/core/admin/doveadm.html
- Let's Encrypt. (2025). *Rate Limits*. 2026年8月閲覧. https://letsencrypt.org/docs/rate-limits/
- nginx. (2026). *Module ngx_http_core_module*. 2026年8月閲覧. https://nginx.org/en/docs/http/ngx_http_core_module.html
- OpenSSL. (2026). *openssl-s_client — OpenSSL Documentation*. 2026年8月閲覧. https://docs.openssl.org/3.5/man1/openssl-s_client/
