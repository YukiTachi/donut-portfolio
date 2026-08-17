---
title: CentOS Stream 9でメールサーバーを建てる――SELinuxを切らずにmail-tester 10/10へ
description: 「メールサーバーは自前で建てるな」と言われる時代に、CentOS Stream
  9上でPostfix+Dovecot+OpenDKIMをSELinux
  enforcingのまま構築し、mail-tester.comで10/10を達成しました。多くの記事が無効化で逃げるSELinuxをaudit2allowで最小限だけ通す実践と、SPF/DKIM/DMARCによる到達可能性の設計を、詰まった順の実録で解説します。
pubDate: 2026-08-16T19:03:00.000+09:00
author: Yuki Tachi
tags:
  - CentOS Stream 9
  - Postfix
  - Dovecot
  - SELinux
  - メールサーバー
draft: false
---

## はじめに

「メールサーバーを自前で建てるのはやめておけ」――半ば常識と化した助言です。個人ドメインからのメールは大手プロバイダに弾かれる、というのがその理由です。しかし、送信ドメイン認証(SPF/DKIM/DMARC)を正しく揃えれば、個人ドメインでも十分に届くメールサーバーは作れます。

本記事では、CentOS Stream 9 上に Postfix + Dovecot + OpenDKIM のメールサーバーを、SELinux を enforcing のまま構築し、到達性採点サービス mail-tester.com で 10/10 を達成するまでの工程を実録として辿ります。多くの構築記事が「SELinux を無効化する」で済ませる部分をカスタムポリシーで通すのが本記事の核です。なお実値(ドメイン・IP・鍵など)はすべて汎用化しています(`example.com` 等)。

## 背景・課題

構成要素と役割分担は次のとおりです。

- Postfix(MTA): SMTP でのメール送受信。バーチャルドメインを MariaDB で管理
- Dovecot: IMAP と SQL ベースの認証。Postfix の SMTP 認証(SASL)も担当
- OpenDKIM: 送信メールへの DKIM 署名(milter として Postfix に接続)
- PostfixAdmin: ドメイン・メールボックス管理の Web UI
- 前提: SELinux は enforcing のまま。ポートは 25(SMTP)/587(submission)/993(IMAPS)

課題は2層あります。第1層は「サーバとして動くこと」。別々のプロセス群を SELinux の制約下で連携させる必要があります。第2層は「送ったメールが届くこと」。こちらは DNS 上の信頼設計(SPF/DKIM/DMARC)で決まります。

Google は2024年2月以降、Gmail 宛に送るすべての送信者に SPF または DKIM の設定、正引き・逆引き DNS(PTR)の整備、TLS 接続を要求し、1日5,000通を超える送信者には SPF・DKIM 両方と DMARC を必須化しました(Google, 2026)。到達可能性は最初から設計対象なのです。

## 本論

### 基本構築――Postfix・Dovecot・MariaDBの三者連携

Postfix のバーチャルドメイン方式では、ドメイン・メールボックス・エイリアスを外部テーブルで管理できます(Postfix, 2026a)。今回は PostfixAdmin のスキーマを MariaDB に置き、Postfix からは mysql マップで参照します。

```ini
virtual_mailbox_domains = mysql:/etc/postfix/mysql_virtual_domains.cf
virtual_mailbox_maps    = mysql:/etc/postfix/mysql_virtual_mailboxes.cf
virtual_alias_maps      = mysql:/etc/postfix/mysql_virtual_aliases.cf
```

DB ユーザーは最小権限の原則で3つに分けました(管理用は全権、Postfix 用・Dovecot 用は SELECT のみ)。なお Postfix/Dovecot からの接続は UNIX ソケット経由になるため DB ユーザーは `localhost` で作成します(`127.0.0.1` とは別扱いになることを構築時に確認しました)。

Dovecot 側は SQL 認証を使います。ここで踏んだのがパスワードスキームの不一致でした。今回の PostfixAdmin(4.x)が生成したハッシュは bcrypt(`$2y$` で始まる)だったため、Dovecot 側は `default_pass_scheme = BLF-CRYPT` の指定が必要でした。BLF-CRYPT は Dovecot における bcrypt の名称です(Dovecot, 2026)。既定のままでは認証だけが失敗し、ログからは原因が見えにくい罠です。

SMTP 認証は Postfix 自身では行わず Dovecot に委譲します。`smtpd_sasl_type = dovecot` とし、UNIX ソケット(`private/auth`)経由で連携する構成は公式にサポートされています(Postfix, 2026b)。587番ポートでは TLS を必須にし、認証済みクライアントのみ中継を許可します。

### SELinuxとの格闘――「設定は正しいのに動かない」の正体

基本設定を終えても、認証とメール配送が `(13) Permission denied` で失敗し続けます。設定を何度見直しても間違いがない――この「設定は正しいのに動かない」症状こそ SELinux 起因の典型です。原因は、Postfix・Dovecot の各プロセスから MariaDB の UNIX ソケットへの接続を SELinux が遮断していることでした。

進め方は段階方式にしました。まず permissive モードで一通り動かして AVC 拒否ログを収集し、ポリシーを整備してから enforcing に戻します。拒否の確認とポリシー化には ausearch と audit2allow を使います(Red Hat, 2026)。

```sh
# 最近のAVC拒否を確認する(まず読む。無批判に許可しない)
sudo ausearch -m avc -ts recent

# プロセス単位で最小のポリシーモジュールを作って導入する
sudo ausearch -c 'auth' --raw | sudo audit2allow -M dovecot_mysql
sudo semodule -i dovecot_mysql.pp
```

ポイントは、Postfix が単一プロセスではないことです。cleanup・trivial-rewrite・smtpd・virtual といった内部プロセスごとに AVC 拒否が発生するため、モジュールも同じ要領で計5本をプロセス単位で作成しました。

ここで規律にしたのは「audit2allow の出力を無批判に投入しない」ことです。生成されるルールは必要以上のアクセスを許すことがあり、Red Hat のドキュメントも生成ポリシーのレビューを推奨しています(Red Hat, 2026)。AVC の内容を読み、対象プロセスとリソースが意図どおりかを確かめてから `semodule -i` する。既存の boolean(`getsebool -a` で確認)で済むものは優先し、カスタムポリシーは最後の手段にする。この手順なら SELinux を切らずに運用できます。

### 証明書の罠――ディレクトリの実行権限

もう1つの「設定は正しいのに動かない」は Let's Encrypt 証明書でした。Dovecot が `/etc/letsencrypt/live/` 配下を読めず Permission denied になります。原因はファイルではなく、`live/` と `archive/` ディレクトリに他ユーザーのトラバース(実行)権限がないことでした。両者を 755 にすれば通ります(秘密鍵は 600 のまま保護されます)。なお、証明書の自動更新とプロセスへの反映(deploy hook)には独立した設計問題があり、[前回の記事](/blog/2026-08-02-lets-encrypt証明書のトラブルシュート実践メール証明書エラー1件から自動更新の設計不備を洗い出す)で詳述しています。

### 到達可能性はDNSで決まる――SPF/DKIM/DMARC

サーバが動いても、認証情報が DNS になければメールは疑われます。3つの仕組みはそれぞれ RFC で定義されています。

- SPF: ドメインの正当な送信元 IP を TXT レコードで宣言する(RFC 7208; Kitterman, 2014)
- DKIM: 秘密鍵でメールに署名し、DNS 上の公開鍵で検証させる(RFC 6376; Crocker et al., 2011)
- DMARC: SPF/DKIM の結果と From ドメインの整合を検証し、不合格時の扱いをポリシーとして宣言する(RFC 9989; Herr & Levine, 2026。旧 RFC 7489 を置き換える現行仕様)

DKIM は OpenDKIM で実装しました。2048ビットの鍵を生成し、KeyTable/SigningTable で署名対象を定義、`inet:8891@localhost` のソケットで待ち受けて Postfix から milter として呼び出します(OpenDKIM Project, 2026)。Postfix 側は `smtpd_milters = inet:localhost:8891` を追加し、公開鍵を `セレクタ._domainkey` の TXT レコードで DNS に登録します。

DMARC は `p=none`(監視のみ)から始めました。レポートを監視しながら段階的にポリシーを強化していく運用モデルは、2026年5月に RFC 7489 を置き換えた現行仕様 RFC 9989 でも踏襲されています(Herr & Levine, 2026)。なお新仕様では、メーリングリスト経由の配送が多いドメインで `p=reject` を安易に用いないよう注意が明確化されており、強化の判断はレポートの実測に基づいて行うべきです。

検証はゴールから逆算します。`dig` で各 TXT レコードの公開を確認し、mail-tester.com にテストメールを送って採点を受けます(mail-tester, 2026)。筆者の場合、初回は満点に届かず、認証や DNS の不備による減点を1つずつ潰して4回目の計測で 10/10 に到達しました(採点項目は執筆時点のものです)。Gmail 宛でも三者すべての pass を確認しています。逆引き(PTR)は VPS 事業者側の設定である点も見落としがちです。

### 運用への接続

実用例として、同居する WordPress の通知メールを WP Mail SMTP 経由の 587/STARTTLS 送信に切り替えました。送信専用アドレスを自ドメインで持てるのは分かりやすい利点です。一方、筆者の環境では公開後まもなく外部からの認証試行が観測されており、fail2ban による防御が次の課題です(本記事のスコープ外とします)。

## 実践への応用・考察

今回の構築を振り返ると、難所はソフトウェア単体の設定ではなく、3つの層に集中していました。

1. OS の防御機構との整合(SELinux のポリシー設計)
2. プロセス間連携(Postfix ↔ Dovecot ↔ MariaDB の認証・ソケット・権限)
3. DNS 上の信頼設計(SPF/DKIM/DMARC と PTR)

とくに1は、「SELinux を無効化する」という近道が流通しているせいで、正攻法の情報が少ない領域です。しかし実際には、AVC 拒否を読む→最小ポリシーを作る→enforcing に戻す、という手順は十分に現実的でした。この経験は他のサービスを SELinux 環境で動かす際にもそのまま応用できます。

3については、mail-tester のような採点サービスで「計測しながら潰す」進め方が有効でした。到達可能性は構成の正しさの積み上げでは保証されず、外部からの見え方を実測して初めて確認できます。前回の証明書の記事で得た「動かしたで終わらせず、壊れたら気づけるまで作る」という教訓と同型です。

## まとめ

- メールサーバー構築の難所は、SELinux との整合・プロセス間連携・DNS の信頼設計の3層に集中する
- SELinux は切らない。AVC 拒否を読み、audit2allow で必要最小限のポリシーをプロセス単位で作る
- 認証失敗の裏には、パスワードスキームや証明書ディレクトリの実行権限など「設定ファイルの外」の原因がある
- 到達可能性は SPF/DKIM/DMARC と PTR の DNS 設計で決まる。mail-tester 等で実測し、減点を1つずつ潰す

「自前メールサーバーは無理」という通説は、正確には「何となく建てただけでは届かない」です。要求される認証を1つずつ満たせば個人ドメインでも 10/10 は達成できます。次は運用編として fail2ban による防御を扱う予定です。

## 参考文献

### 公式ドキュメント

- Crocker, D., Hansen, T., & Kucherawy, M. (2011). *DomainKeys Identified Mail (DKIM) Signatures* (RFC 6376). Internet Engineering Task Force. https://www.rfc-editor.org/rfc/rfc6376.html
- Dovecot. (2026). *Password Schemes — Dovecot CE documentation*. 2026年8月閲覧. https://doc.dovecot.org/2.3/configuration_manual/authentication/password_schemes/
- Google. (2026). *Email sender guidelines*. 2026年8月閲覧. https://support.google.com/a/answer/81126
- Herr, T., & Levine, J. (Eds.). (2026). *Domain-Based Message Authentication, Reporting, and Conformance (DMARC)* (RFC 9989). Internet Engineering Task Force. https://www.rfc-editor.org/rfc/rfc9989.html
- Kitterman, S. (2014). *Sender Policy Framework (SPF) for Authorizing Use of Domains in Email, Version 1* (RFC 7208). Internet Engineering Task Force. https://www.rfc-editor.org/rfc/rfc7208.html
- OpenDKIM Project. (2026). *opendkim (filter) README File*. 2026年8月閲覧. http://www.opendkim.org/opendkim-README
- Postfix. (2026a). *Postfix Virtual Domain Hosting Howto (VIRTUAL_README)*. 2026年8月閲覧. https://www.postfix.org/VIRTUAL_README.html
- Postfix. (2026b). *Postfix SASL Howto (SASL_README)*. 2026年8月閲覧. https://www.postfix.org/SASL_README.html
- Red Hat. (2026). *Using SELinux — Chapter 8. Writing a custom SELinux policy* (RHEL 9). 2026年8月閲覧. https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_selinux/writing-a-custom-selinux-policy_using-selinux

### Web記事

- mail-tester. (2026). *Newsletters spam test by mail-tester.com*. 2026年8月閲覧. https://www.mail-tester.com/
