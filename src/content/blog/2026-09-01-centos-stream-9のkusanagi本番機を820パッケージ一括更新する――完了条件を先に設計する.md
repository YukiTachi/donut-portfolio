---
title: CentOS Stream 9のKUSANAGI本番機を820パッケージ一括更新する――完了条件を先に設計する
description: WordPressとメールサーバーが同居するKUSANAGI(CentOS Stream 9)の本番VPSで、カーネル・glibc・OpenSSL・openssh・PHP・MariaDBを含む820パッケージを`dnf upgrade`で一括更新した実録です。820個のうち本当に壊れうるのはSSH・TLS/DKIM・カーネル・PHPの4系統と見立て、「何を確認すれば完了と言えるか」を実行前に決めました。AIが提案した世代違いの手順をKUSANAGI公式で検証して訂正した経緯も含め、公式ドキュメントとdnf/rpmの一次資料に基づいて整理します。
pubDate: 2026-09-01T19:00:00.000+09:00
author: Yuki Tachi
tags:
  - CentOS Stream
  - KUSANAGI
  - dnf
  - 運用設計
  - メールサーバー
  - AI検証
draft: true
---

## はじめに

「`dnf upgrade` で合っていますか」。筆者はこの一言から始めました。対象は WordPress とメールサーバーが同居する KUSANAGI の VPS(CentOS Stream 9)。しばらく更新を止めていたため更新対象は 820 パッケージに達し、カーネルから glibc、systemd、OpenSSL、openssh、crypto-policies、KUSANAGI 本体、nginx、PHP、MariaDB、postfix、dovecot まで、要するに全部が含まれていました。

一度に 820 個が来る恐さはありますが、放置するほうが危険です。本記事では 2026 年 6 月上旬に実施したこの一括更新を、「コマンドを知っているか」ではなく「何を確認すれば完了と言えるかを先に決められるか」という観点で整理します。実 IP・実ドメイン・ポート番号は伏せ、構成は汎用化しています。

## 背景・課題

まず、なぜ差分が積み上がるのか。CentOS Stream は「継続的に配信されるディストリビューションで、Red Hat Enterprise Linux(RHEL)開発の少し先を進み、Fedora Linux と RHEL の中間に位置する」と公式に説明されています(The CentOS Project, 2026a)。FAQ でも、修正と機能は RHEL より先に CentOS Stream へ入ると明記されています(The CentOS Project, 2026b)。更新を止めた期間がそのまま差分の山になります。ただし「ローリングリリース」ではなく、メジャーバージョン(9)のブランチ内で RHEL の次のマイナーリリースの内容が先行して流れてくる、という理解が近いでしょう。

次に KUSANAGI 側の更新手順です。KUSANAGI 9 の公式リリース情報は、本体・モジュールのいずれも「以下のコマンドで適用可能です。`# dnf upgrade`」とし、モジュール更新では「アップデート後、以下のコマンドで KUSANAGI 9 を再起動してください。`# kusanagi restart`」と続けています(KUSANAGI, 2026a; 2026b)。固有の更新コマンドはなく、OS と同じ `dnf upgrade` に載っているのが 2026 年 8 月時点の公式手順です。

準備として、VPS 事業者のスナップショットを取得し、「戻せる」状態にしてから作業に入りました。

## 本論

### AI の助言を公式手順で検証する

作業に先立ち AI アシスタントに手順を尋ねると、「OS は `dnf upgrade` で、KUSANAGI のミドルウェアは分けて `kusanagi update` 系のコマンドで更新すべき」という助言が返ってきました。もっともらしく聞こえますが、筆者の記憶では KUSANAGI 9 の公式は `dnf upgrade` のみ。その旨を指摘すると、AI は公式リリース情報を確認したうえで助言を撤回しました。

これは[以前の記事](/blog/2026-07-12-aiが書いた記事をどう信用するか出典検証を仕組みにする/)で整理した「型③: 出典側の記述変更に取り残された古い事実」の実例です。旧世代の手順が学習データに残っていれば、AI は世代の違う手順を自信をもって出します。本記事も同じ誤りを避けるため、KUSANAGI の現行リリース情報(2026 年 8 月 28 日付)を原文で確認しています(KUSANAGI, 2026b)。

### 820 個を「壊れたときに致命的な順」に並べる

820 個を個別に評価する代わりに、「壊れたら復旧が難しい順」に系統を並べ、それぞれ何を確認すれば閉じられるかを先に決めました。

**第 1 系統: openssh + crypto-policies → 締め出し。** SSH で入れなくなると復旧手段は事業者のコンソールだけです。RHEL 9 のシステム全体の暗号化ポリシーは「TLS、IPsec、SSH、DNSSec、Kerberos の各プロトコルを対象に、中核となる暗号サブシステムを設定するシステムコンポーネント」であり、OpenSSH も対象です(Red Hat, 2026)。確認項目は「作業セッションを残したまま、別端末から新規 SSH ログインが成功すること」。

**第 2 系統: OpenSSL + crypto-policies → TLS と DKIM が黙って壊れる。** Postfix の公式文書は、TLS を有効にすると「数十万行の OpenSSL ライブラリコードも有効になる」と表現しています(Postfix, 2026)。OpenDKIM も OpenSSL を必須依存としています(The Trusted Domain Project, 2026)。暗号化ポリシーは「アプリケーションの起動時に適用される」ため、再起動して初めて新しい挙動になります(Red Hat, 2026)。確認項目は「受信側のヘッダで SPF・DKIM・DMARC の 3 点が PASS であること」。

**第 3 系統: カーネル・glibc・systemd → 再起動が必要。** 判定には dnf-plugins-core の `needs-restarting` を使います。`-r` は「再起動が必要か(終了コード 1)否か(終了コード 0)だけを報告する」オプションで(dnf-plugins-core, 2026)、実装上は kernel、glibc、linux-firmware、systemd、dbus などのインストール時刻がブート時刻より後かを見ています(rpm-software-management, 2026a)。確認項目は「再起動後に `needs-restarting -r` が 0 を返し、全サービスが起動していること」。

**第 4 系統: PHP のマイナー更新 → WordPress。** WordPress の公式要件は PHP 8.3 以上を推奨しています(WordPress, 2026)。今回は 8.3 系内のパッチ更新ですが、拡張モジュールの読み込み失敗は管理画面を開くまで分かりません。確認項目は「フロントの描画と管理画面へのログイン」。

「820 個を更新した」ではなく「4 つの確認が通った」が完了の定義です。

### 実行と再起動、そして確認

実行の要点のみ抜粋します。

```sh
dnf check-update | wc -l   # 更新対象の規模を把握
dnf upgrade                # 820 パッケージ、エラーなしで完走
needs-restarting -r        # 終了コード 1 → 再起動が必要
kusanagi restart           # KUSANAGI 公式手順どおり
reboot
```

再起動後の主要バージョンは、カーネル 5.14.0-710、KUSANAGI 9.8.13、nginx 1.29.8、PHP 8.3.31、MariaDB 10.6.27、openssh 9.9p1、kusanagi-openssl 3.5.5 → 3.5.6 でした。いずれも 2026 年 6 月時点の実値で、「現在の最新」ではありません。

1. **別端末からの SSH 新規ログイン**(第 1 系統)――成功。
2. **WordPress のフロント描画と管理画面ログイン**(第 4 系統)――成功。
3. **外部メールボックス宛にテスト送信し、受信側ヘッダで SPF・DKIM・DMARC を確認**(第 2 系統)――3 点とも PASS。

第 3 系統は `needs-restarting -r` が 0 を返し、`kusanagi status` で全サービスの起動を確認して閉じました。

### 副産物: `.rpmnew` とバージョン付きサービス名

更新後、リポジトリ定義の `.rpmnew` が 2 件残りました。rpm の仕様では、`%config(noreplace)` 指定の設定ファイルは「ローカルで変更されていればパッケージ更新時にそのまま保持され、パッケージ側の新しい内容は参照用に `.rpmnew` 接尾辞で保存される」と定められています(rpm-software-management, 2026b)。「あなたの変更は守った。新しい既定値はこちら」という通知であり、放置しても動作は変わりません。

もう 1 つは、KUSANAGI のサービス名がバージョン番号込み(`nginx129` など)である点です。[証明書更新の記事](/blog/2026-08-02-lets-encrypt証明書のトラブルシュート実践メール証明書エラー1件から自動更新の設計不備を洗い出す/)と[Winter CMS 相乗りの記事](/blog/2026-08-24-kusanagiにwinter-cmsを相乗りさせるwordpress専用ディストリで別cmsを本番稼働させるまで/)で触れたとおり、nginx の版が上がるとサービス名も変わり得ます。今回は変わりませんでしたが、「`kusanagi status` に想定したサービス名が並ぶこと」も確認項目に含めておくと安全です。

## 実践への応用

今回の更新から一般化できることを 3 つ挙げます。

第 1 に、**完了条件を先に設計する**。820 個という数字に圧倒されず「壊れたら致命的な系統」に絞ると 4 つになりました。それぞれに「これが通れば閉じる」確認を対応づけておけば、事後確認は手順の消化ではなく仮説の検証になります。

第 2 に、**AI の手順提案は公式で検証する**。AI が自信をもって出す手順ほど、「いま公式は何と書いているか」を見に行く価値があります。

第 3 に、**静かに壊れるものを先に疑う**。SSH の締め出しは気づけますが、DKIM の署名失敗や TLS の退行は、送ったメールが迷惑メール扱いになるまで気づけません。暗号化ポリシーが起動時に適用される仕様(Red Hat, 2026)を踏まえると、再起動後の確認こそが本番です。[メールサーバー構築の記事](/blog/2026-08-16-centos-stream-9でメールサーバーを建てるselinuxを切らずにmail-tester-10-10へ/)で用意した「受信側ヘッダで 3 点 PASS」の手順が、そのまま更新後の完了条件として再利用できました。

推測を明示しておきます。「openssh と crypto-policies の同時更新で締め出される可能性」は、SSH がポリシーの対象であるという仕様から筆者が導いた見立てで、今回の環境で締め出しが起きたわけではありません。

## まとめ

- CentOS Stream は RHEL 開発の少し先を継続的に配信する(The CentOS Project, 2026a)。更新を止めた期間がそのまま差分になる
- KUSANAGI 9 の公式手順は `dnf upgrade` のあと `kusanagi restart`(KUSANAGI, 2026a; 2026b)。固有の更新コマンドは不要
- 820 個の更新対象は「壊れたら致命的な順」に SSH、TLS/DKIM、カーネル、PHP の 4 系統へ絞れる。見立てがそのまま事後確認になる
- AI の手順提案は世代違いのことがある。公式のいまの記述で照合する

次は、この 4 系統の確認を `needs-restarting -r`・SSH 疎通・HTTP 200・メール認証ヘッダの自動チェックに落とし、更新のたびに同じ判定を再現できる形にする予定です。

## 参考文献

本記事は技術テーマのため学術論文は参照せず、公式ドキュメント(一次資料)と筆者環境での実測に基づいています。

### 公式ドキュメント

- dnf-plugins-core. (2026). *DNF needs-restarting Plugin*. dnf-plugins-core documentation. 2026年9月閲覧. https://dnf-plugins-core.readthedocs.io/en/latest/needs_restarting.html
- KUSANAGI. (2026a). *KUSANAGI 9 バージョンアップ情報 9.10.2-1*. 超高速CMS実行環境 KUSANAGI. 2026年7月29日公開, 2026年9月閲覧. https://kusanagi.tokyo/releases/25940/
- KUSANAGI. (2026b). *kusanagi-openssl モジュール更新情報 3.5.8-1*. 超高速CMS実行環境 KUSANAGI. 2026年8月28日公開, 2026年9月閲覧. https://kusanagi.tokyo/releases/26428/
- Postfix. (2026). *Postfix TLS Support*. 2026年9月閲覧. https://www.postfix.org/TLS_README.html
- Red Hat. (2026). *Chapter 4. Using system-wide cryptographic policies*. Red Hat Enterprise Linux 9 Security hardening. 2026年9月閲覧. https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/using-the-system-wide-cryptographic-policies_security-hardening
- rpm-software-management. (2026a). *needs_restarting.py*. dnf-plugins-core (GitHub). 2026年9月閲覧. https://github.com/rpm-software-management/dnf-plugins-core/blob/master/plugins/needs_restarting.py
- rpm-software-management. (2026b). *rpm-spec(5)*. RPM Manual. 2026年9月閲覧. https://rpm-software-management.github.io/rpm/man/rpm-spec.5
- The CentOS Project. (2026a). *CentOS Stream*. 2026年9月閲覧. https://www.centos.org/centos-stream/
- The CentOS Project. (2026b). *CentOS Stream FAQ*. 2026年9月閲覧. https://www.centos.org/distro-faq/
- The Trusted Domain Project. (2026). *OpenDKIM README*. GitHub. 2026年9月閲覧. https://github.com/trusteddomainproject/OpenDKIM/blob/master/README
- WordPress. (2026). *Requirements*. WordPress.org. 2026年9月閲覧. https://wordpress.org/about/requirements/
