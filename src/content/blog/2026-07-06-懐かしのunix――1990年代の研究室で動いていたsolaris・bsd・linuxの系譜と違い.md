---
title: 懐かしのUnix――1990年代の研究室で動いていたSolaris・BSD・Linuxの系譜と違い
description: 1990年代の大学の研究室には、Solaris・SunOS・BSD/OS・FreeBSD・NetBSD・OpenBSD・Vine
  Linuxという7つのUnix系OSが同居していました。この顔ぶれは、AT&T Unix→BSDの系譜、SVR4、そしてゼロから書かれたLinuxが併存した1990年代Unix界の縮図です。USL
  v. BSDi訴訟という転換点、日本発のKAMEプロジェクトが結んだBSDのIPv6史を交えながら、系譜・ライセンス・開発モデルの3軸でUnixとLinuxの違いを読み解きます。
pubDate: 2026-07-06T19:00:00.000+09:00
author: Yuki Tachi
tags:
  - Unix
  - BSD
  - FreeBSD
  - OpenBSD
  - NetBSD
  - Solaris
  - Linux
  - IPv6
  - 歴史
draft: true
---

## はじめに

1990年代後半、筆者が過ごした大学の研究室には、SolarisとSunOSのSun製ワークステーション、NetBSDを入れたSPARC機、OpenBSDのマシン、Vine LinuxのPCが同居していました。入学時に自費で買ったノートPCはWindowsとBSD/OSのデュアルブート。いま振り返るとこの顔ぶれは、商用Unix・無償BSD・黎明期Linuxが併存した1990年代Unix界の縮図でした。

本記事では、これらのOSがどの系譜に属し、なぜ多様なUnixが一つの部屋に同居していたのか、UnixとLinuxは何が違うのかを、公式の沿革と筆者の一次体験を交えて振り返ります。

## 背景・課題――系譜の地図

Unixの本流は、AT&Tベル研究所で生まれたUnixと、そこから枝分かれしてカリフォルニア大学バークレー校で発展したBSD（Berkeley Software Distribution）です。一方AT&T側は、System VにBSDやSunOS、Xenixの機能を統合したSVR4（System V Release 4）を1980年代末にまとめ上げました（Wikipedia「SunOS」）。そして1991年、Linus Torvaldsがニュースグループcomp.os.minixでカーネルの自作を予告し、同年9月にLinux 0.01を公開します（Wikipedia「History of Linux」）。LinuxはUnixのコードを継いでおらず、GNUのユーザーランドと組み合わせて使われます。

本記事では、AT&T UnixやBSDのコードを遺伝的に継ぐ系統を「Unix系」、コードは継がずインタフェースを模倣したLinuxを「Unix風」と区別します。なお「UNIX」商標はThe Open Groupが管理し、Single UNIX Specification認証を通過したOSだけが名乗れます（The Open Group）。Linuxディストリビューションの大半はこの認証を受けていません。

## 本論

### 同じSunでも中身の系譜が違う――SunOSとSolaris

研究室の主力はSun製ワークステーションでした。1台はWeb・メール・DNS・NIS+を担うSolarisの基幹サーバ、もう1台は用途を思い出せないSunOS機です。同じベンダーの2台ですが、中身の系譜は違います。SunOS 4.xまではBSD由来のOSでしたが、Sunは1991年9月に次期OSをSVR4ベースへ切り替えると発表し、SunOS 5.xをSolarisの名で1992年に出荷しました（Wikipedia「SunOS」）。用途不明のSunOS機はおそらくBSD由来の4.x世代でしょう（筆者の推定です）。

NIS+は、Solaris 2とともに1992年に登場したNIS（Network Information Service）の後継で、ホスト名やユーザーアカウントを階層構造で集中管理する仕組みです（Wikipedia「NIS+」）。研究室の全マシンのアカウント一元管理は、この時代のSun流そのものでした。

### 商用と無償、系譜は別の軸――BSD/OSという商用BSD

筆者のノートPCに入っていたBSD/OSは、CSRG（バークレーのBSD開発グループ）のメンバーらが1991年に設立したBSDi（Berkeley Software Design, Inc.）の商用OSです。前身のBSD/386は1992年1月に発売され、自由に再配布できたNet/2をベースに、ソースコード込み995ドルで販売されました（Wikipedia「Berkeley Software Design」）。Solarisが「商用でSVR4系」なのに対し、BSD/OSは「商用だがBSD系」。商用か無償かという軸と、どの系譜かという軸は独立している――BSD/OSはそれを教えてくれる実物でした。

### 三兄弟と、それを結んだKAME――FreeBSD・NetBSD・OpenBSD

無償のBSDは、Jolitz夫妻がNet/2をIntel 386に移植した386BSDから始まりました。1993年、その開発の停滞を機にNetBSDとFreeBSDが相次いで分岐します（NetBSDのリポジトリ開設は3月21日、FreeBSDは6月19日に命名され1.0は同年11月。netbsd.org、Wikipedia「FreeBSD」）。さらに1995年10月、NetBSDの創設メンバーだったTheo de RaadtがNetBSD 1.0を基にOpenBSDを立ち上げます（Wikipedia「OpenBSD」）。三者の性格は、FreeBSDはx86での性能と実用、NetBSDは移植性（"of course it runs NetBSD"）、OpenBSDは徹底したコード監査によるセキュリティです。筆者がSPARC機にNetBSDを入れたのは移植性の恩恵そのものですし、OpenBSDを入れたマシンもありました。ノートPCも3年次にBSD/OSを消してFreeBSDへ――商用BSDから無償BSDへのこの乗り換え自体が、1990年代後半の潮流を映しています。

この4つのBSDをネットワーク実装の面で結んだのが、WIDEプロジェクト傘下で日本の6組織が1998年に始めたKAMEプロジェクトです。IPv6・IPsec・Mobile IPv6の無償リファレンス実装をBSD各系統に提供し、2006年3月末で終了しました。名は事務所所在地のKarigome（カリゴメ）に由来します（Wikipedia「KAME project」）。成果は4つのBSDすべてにマージされ、FreeBSD 4.0（2000年3月）のリリースノートにはIPv6とIPsecの双方をKAMEから取り込んだと明記されています（FreeBSD Project, 2000）。興味深いのはOpenBSDで、OpenBSD 2.7（2000年6月）が収載したのは "Latest KAME IPv6"――IPv6コードのみでした（OpenBSD Project, 2000）。IPsecは1997年から自前のスタックを備えており、外部実装には置き換えなかったのです（Wikipedia「OpenBSD」）。セキュリティ最優先の独立性が、コード採用の判断にも表れています。

IPv4アドレス枯渇が言われ始めたころ、筆者はgifインタフェースでIPv4上にIPv6をトンネルし、kame.netの「亀が踊るか」で疎通を確かめました。亀のアニメーションはIPv6でアクセスしたときだけ踊る仕掛けだったと記憶しています。

### 日本語と戦っていたLinux――Vine Linux

研究室のPCではVine Linuxも動いていました。Vine Linux 1.0は1998年11月16日にリリースされた国産ディストリビューションで、Red Hat Linux 5.2をベースに、PJE（Project Japanese Extensions）のメンバーらが日本語環境を整備したものです（Project Vine, 1998; ITmedia, 2021）。EUC-JPにkterm、WnnやCannaでの日本語入力――「日本語がまともに使える」こと自体に価値があった時代です。一体で開発されるBSDと違い、Linuxはカーネルとユーザーランドをディストリビューションという形で束ねて普及しました。日本語対応のような地域固有の要求に応えられたのは、この開発モデルゆえです。

### なぜ同居していたのか――UnixとLinuxの違いの核心

同居の理由は、4つの軸で整理できます。

第一に系譜。SolarisはSVR4系、BSD勢は遺伝的にUnix、LinuxはUnix風の別系統です。第二にライセンス。BSDライセンスは再配布や商用利用にほぼ制限のない寛容型で、GPLは派生物にもソース公開を求めるコピーレフト型です（Open Source Initiative; Free Software Foundation）。第三に史実の転換点。USL（AT&TのUnix子会社）は1992年4月、Net/2由来のBSD/386が知的財産を侵害するとしてBSDiを提訴しました。訴訟は1994年2月に和解し、係争部分を除いた4.4BSD-Liteの公開で決着します――約18,000ファイル中、削除はわずか3、修正は70でした（Wikipedia「USL v. BSDi」）。しかしこの約2年間、BSDには法的な不透明感が漂い、ちょうどその空白を縫うようにLinuxが伸びました。第四に開発モデル。カーネルからユーザーランドまで一体の統合OSとして開発されるBSDと、カーネル＋ディストリビューションのLinux。だから1990年代の現場には、商用Unix・無償BSD・Linuxがそれぞれの強みで居場所を持っていたのです。

## 実践への応用・考察

系譜・ライセンス・開発モデルの3軸は、現在の景色を読むレンズとしてそのまま使えます。macOSの土台にはBSD由来のコードが流れ込んでおり、macOSはSingle UNIX Specificationの認証を受けた「UNIX」です（The Open Group）。一方、サーバの主流となったLinuxは、商標上のUNIXではないまま事実上の標準になりました。

筆者自身、学生時代の乗り換え以来、四半世紀FreeBSDを使い続けており、本サイトもFreeBSD上で動いています。研究室にあったOSたちの系譜を辿り直すと、なぜmacOSがUnixらしいのか、なぜLinuxにはディストリが多いのか――現在の景色が地続きに見えてきます。歴史は暗記物ではなく、現在を説明する道具です。

## まとめ

- 1990年代の研究室にはSolaris（SVR4系）・SunOS（BSD系）・BSD/OS（商用BSD）・FreeBSD/NetBSD/OpenBSD（無償BSD）・Vine Linux（Unix風）が同居していた。
- 「商用か無償か」と「どの系譜か」は独立した軸である。BSD/OSは商用だが系譜はBSDだった。
- USL v. BSDi訴訟（1992提訴〜1994和解）による法的不透明期が、Linux普及の追い風になった。
- 日本発のKAMEプロジェクト（1998〜2006）はIPv6/IPsec実装で4つのBSDを結んだ。OpenBSDがIPv6のみを採用した判断に、その性格が表れている。
- UnixとLinuxの違いは、系譜・ライセンス・開発モデルの3軸で整理できる。

昔使っていたマシンのOSがどの系譜だったか、一度調べ直してみてください。いま目の前にあるOSの景色が少し違って見えるはずです。

## 参考文献

### 公式ドキュメント

- Free Software Foundation. *What is Copyleft?*. 2026年7月閲覧. https://www.gnu.org/licenses/copyleft.html
- FreeBSD Project (2000). *FreeBSD 4.0-RELEASE Release Notes*. 2026年7月閲覧. https://www.freebsd.org/releases/4.0R/notes/
- NetBSD Project. *The History of the NetBSD Project*. 2026年7月閲覧. https://www.netbsd.org/about/history.html
- Open Source Initiative. *The 3-Clause BSD License*. 2026年7月閲覧. https://opensource.org/license/bsd-3-clause
- OpenBSD Project (2000). *OpenBSD 2.7 Release*. 2026年7月閲覧. https://www.openbsd.org/27.html
- Project Vine (1998). *Vine Linux 1.0 リリースについて*. 2026年7月閲覧. https://vinelinux.org/news/19981116.html
- The Open Group. *UNIX Certification Program*. 2026年7月閲覧. https://www.opengroup.org/certifications/unix

### Web記事

- ITmedia NEWS (2021). 「Vine Linux」リリース終了 1998年誕生、国産Linuxディストリビューションの先駆け. 2026年7月閲覧. https://www.itmedia.co.jp/news/articles/2105/07/news109.html
- Wikipedia. *Berkeley Software Design*. 2026年7月閲覧. https://en.wikipedia.org/wiki/Berkeley_Software_Design
- Wikipedia. *FreeBSD*. 2026年7月閲覧. https://en.wikipedia.org/wiki/FreeBSD
- Wikipedia. *History of Linux*. 2026年7月閲覧. https://en.wikipedia.org/wiki/History_of_Linux
- Wikipedia. *KAME project*. 2026年7月閲覧. https://en.wikipedia.org/wiki/KAME_project
- Wikipedia. *NIS+*. 2026年7月閲覧. https://en.wikipedia.org/wiki/NIS%2B
- Wikipedia. *OpenBSD*. 2026年7月閲覧. https://en.wikipedia.org/wiki/OpenBSD
- Wikipedia. *SunOS*. 2026年7月閲覧. https://en.wikipedia.org/wiki/SunOS
- Wikipedia. *UNIX System Laboratories, Inc. v. Berkeley Software Design, Inc.*. 2026年7月閲覧. https://en.wikipedia.org/wiki/UNIX_System_Laboratories,_Inc._v._Berkeley_Software_Design,_Inc.
