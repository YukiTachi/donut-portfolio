---
title: FreeBSD上のClaude Codeが応答のあと固まる（3）――時刻とソースで確定したepoll_pwait2バグ
description: 第2部で立てた「アプリ側の競合」という仮説は誤りでした。ktraceを時刻順に並べ直すと、イベントループのepoll_pwait2がシグナルを受けたのにEINTRではなく0を返していました。Linuxulatorのソースを読み、古いシグナルマスクが復元される仕組みを特定し、最小再現でLinuxと比較し、同じ日に報告されていたFreeBSD
  Bug 298878に確認結果で合流するまでの記録です。3部作の第3部です。
pubDate: 2026-11-20T06:00:00.000+09:00
author: Yuki Tachi
tags:
  - FreeBSD
  - Linuxulator
  - Claude Code
  - ktrace
  - カーネル
  - トラブルシューティング
draft: false
---

## はじめに

[第1部](/blog/2026-09-29-freebsd上のclaude-codeが応答のあと固まる1固まったを観測で分け版を固定する/)ではメインスレッドがfutexで眠り続けていることを、[第2部](/blog/2026-11-01-freebsd上のclaude-codeが応答のあと固まる2ktraceとdtraceでカーネル側から追う/)ではSIGPWRが届いたままブロックされていることを確かめ、「アプリ側の手順上の競合」という仮説を立てました。この仮説は誤りでした。

本記事は3部作の最終部です。原因をLinuxulator（FreeBSDのLinux互換層）の不具合と確定し、既存の報告に合流し、パッチで直るまでを扱います。

## 背景・課題

第2部の推論には2つの穴がありました。1つは、DTraceで見た `kern_sigprocmask` がアプリの要求だけでなくカーネル内部からも呼ばれる点です。もう1つは、ktraceの出力を `futex` と `sigprocmask` で `grep` して読んでいた点です。この絞り込みが、メインスレッドが実際に何をしていたかを視界から外していました。

そこで、絞り込みをやめてメインの全システムコールを時刻順に読み直すことにしました。

## 本論

### 時刻で並べ直す

`kdump -H -T` はスレッドIDと絶対時刻を付けて表示します（FreeBSD Project, 2026a）。第2部と同じく、PIDは例示値、時刻は秒の下位桁だけを残しています。

```text
186043 2.1.283     004.991078 CALL linux_epoll_pwait2(0x3,0x3de8d8000e0,0x400,0xffffffffc000,0xffffffffbe80,0x8)
197984 HTTP Client 005.060680 CALL linux_tgkill(12345,12345,SIGPWR)
197984 HTTP Client 005.060690 RET  linux_tgkill 0
197984 HTTP Client 005.060701 CALL linux_sys_futex(0x565c880,0x189,0,0,0,0xffffffff)
186043 2.1.283     005.060711 RET  linux_epoll_pwait2 0
186043 2.1.283     005.060721 CALL linux_sys_futex(0x3de9a362ce0,0x189,0xce,0,0,0xffffffff)
```

tgkillからメインが待ちに入るまでの約40マイクロ秒に、メインは `rt_sigprocmask` を呼んでいません。メインはイベントループの `epoll_pwait2` で待っており、第5引数にシグナルマスクを渡していました。そして、tgkillが戻ってから約21マイクロ秒後に、シグナルで起こされたはずの `epoll_pwait2` が **EINTRではなく0** を返しています。

Linuxの `epoll_pwait` のマスク引数は `pselect` と同じく「マスクの差し替え・待機・復元を不可分に行う」もので、シグナルで中断されれば `EINTR` を返します（Linux man-pages project, 2026）。0が返り、ハンドラも動かないのは、この約束から外れています。

### ソースを読む

`linux_epoll_wait_ts()` の該当部分（releng/15.1）を抜粋します（FreeBSD Project, 2026b）。

```c
if (uset != NULL) {
	error = kern_sigprocmask(td, SIG_SETMASK, uset, &omask, 0);
	...
	td->td_pflags |= TDP_OLDMASK;
	ast_sched(td, TDA_SIGSUSPEND);
}
...
error = kern_kevent_fp(td, epfp, 0, maxevents, &k_ops, tsp);
...
if (uset != NULL)
	error = kern_sigprocmask(td, SIG_SETMASK, &omask, NULL, 0);
```

AST（ユーザーモードへ戻る直前に実行されるカーネルの後処理）に登録された `ast_sigsuspend()` は、スレッド構造体の `td_oldsigmask` をマスクとして書き戻します（FreeBSD Project, 2026c）。読み取れる問題は3つです。

1. 元のマスクをローカル変数 `omask` に保存しながら、`TDP_OLDMASK` を立ててASTを予約している。戻り際のASTは、この関数が一度も書いていない古い `td_oldsigmask` を復元する
2. `kevent` の `EINTR` が、最後の `kern_sigprocmask` の戻り値（0）で上書きされる
3. 一時マスクでのみ許可されたシグナルは、配送される前にマスクが戻される

ネイティブの `pselect` は元のマスクを `td_oldsigmask` に保存し、`EINTR` なら `TDA_SIGSUSPEND`、そうでなければ `TDA_PSELECT` をASTに予約して、復元をASTに任せています（FreeBSD Project, 2026d）。epollだけがこの作法から外れていました。

### 因果の鎖

では、古い `td_oldsigmask` には何が入っていたのか。同じ記録の、最初のGC停止要求を見ます。

```text
186043 2.1.283 974.937713 RET  linux_epoll_pwait2 0
186043 2.1.283 974.937718 PSIG SIGRT33 caught handler=0x3a9a9c0 mask=0x0 code=SI_LWP
186043 2.1.283 974.937732 CALL linux_rt_sigsuspend(0xffffffffab30,0x8)
186043 2.1.283 974.937824 PSIG SIGRT33 caught handler=0x3a9a9c0 mask=0x0 code=SI_LWP
186043 2.1.283 974.937826 RET  linux_rt_sigsuspend -1 errno -4 Interrupted system call
```

SIGPWR（kdump上は `SIGRT33`）のハンドラの中で `rt_sigsuspend` が呼ばれ、入れ子のSIGPWRで戻っています。`kern_sigsuspend()` は呼び出し時のマスクを `td_oldsigmask` に保存するので（FreeBSD Project, 2026c）、ここに「ハンドラ実行中＝SIGPWRをブロックしたマスク」が残ります。以後、メインが `epoll_pwait2` から戻るたびにASTがそのマスクを復元し、メインはSIGPWRをブロックした状態になります。約30秒後の次の停止要求は、`EINTR` ごと消え、`PB`（保留・ブロック中）のまま誰も応答しません。

修正コミットの説明も同じ筋道を述べています。JavaScriptCore（BunのJSエンジン）はGCのスタック走査のためSIGPWRでスレッドを止め、ハンドラ内でSIGPWRをブロックしたまま `sigsuspend` する。Bunは常に空のマスクを `epoll_pwait2` に渡す。影響はClaude Code 2.1.269以降とopencodeだとしています（Junka, 2026a）。

この鎖で、「しばらく動いたあと、ある停止要求で固まる」「本物のLinuxでは起きない」「amd64・arm64の両方で起きる」がすべて説明できます。第2部のDTraceで見た3段のマスク変化も、スタックは取っていないので推定ですが、epollの一時マスクの出し入れとASTによる復元だったと考えられます。2.1.282で頻度が上がった理由は、筆者には分かっていません。

### 最小再現

Claude Codeなしの再現プログラムをCで書きました。同じソースをWSL上でx86_64用とaarch64用にそれぞれビルドし（aarch64用は `aarch64-linux-gnu-gcc -O2 -static -pthread`）、x86_64版をLinux（WSL2、5.15系）で、aarch64版をFreeBSD 15.1（arm64）で実行しました。

- テストA：通常はブロックしているSIGUSR1を一時マスクでのみ許可し、`epoll_pwait` 中に別スレッドから送る
- テストB：`sigsuspend` の後に単純な `epoll_pwait` を呼び、目印のSIGUSR2がブロック状態に化けないか見る

| 環境 | テストA | テストB |
|------|---------|---------|
| Linux 5.15（WSL2、x86_64） | -1・EINTR、マスク正常 | 目印ブロックなし |
| FreeBSD 15.1（arm64、修正前） | 0を返しマスクが壊れる | 目印がブロックされる |

ソースはBug 298878の[Comment 8](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=298878#c8)に添付しています。

### 報告しようとしたら

FreeBSDのBugzillaに報告する前に検索すると、同じ2026年9月26日に、Grzegorz Junka さんがテスト済みのパッチとamd64・i386用のテスト付きで報告していました（FreeBSD Project, 2026e）。原因を2017年のコミット80c7315d17ceまで遡る分析も含め、筆者がたどり着いた結論と同じでした。重複報告はせず、arm64での確認結果を書き込む形で合流しました。原因の分析からパッチまで用意してくださったJunkaさんに感謝します。

GitHubのissue #96931では、第2部の仮説を投稿した当日のうちに訂正コメントを出し（Tachi, 2026a）、298878へのリンクを示しました（Tachi, 2026b）。

### パッチを当てて確かめる

cgitからmainの修正コミット（16a284b1cdfd）をパッチ形式で取得してreleng/15.1のソースに当て、`linux64.ko` だけを作り直しました。stable/15のコミット（0143078248bb）も同じ変更です。

```sh
git clone --depth 1 --filter=blob:none --sparse -b releng/15.1 https://git.freebsd.org/src.git ~/src
cd ~/src && git sparse-checkout set sys && git sparse-checkout add include
fetch -o /tmp/pr298878.patch \
  'https://cgit.freebsd.org/src/patch/?id=16a284b1cdfd45ba99c2723e7f88497e76b235ad'
cd ~/src && git apply --check /tmp/pr298878.patch && git apply /tmp/pr298878.patch
cd ~/src/sys/arm64/conf && config -d /tmp/kbuild-generic GENERIC
cd ~/src/sys/modules/linux64
make SRCTOP=$HOME/src SYSDIR=$HOME/src/sys KERNBUILDDIR=/tmp/kbuild-generic
```

詰まった点は2つです。カーネル外の単独ビルドでは構成ヘッダーが空になり、浮動小数点まわりの未使用エラーで止まります。`-Werror` を外して通すのは危険で、`config -d` で生成したヘッダーを `KERNBUILDDIR` で渡すのが正解でした。また、`make install` 先の `/boot/modules` より `/boot/kernel` が先に探されるため、`/boot/kernel/linux64.ko` を退避して置き換えました。

結果、再現プログラムはLinuxと一致し、Claude Code 2.1.283は1時間以上の普段使いで一度も固まりませんでした。この結果をBugzillaのComment 7に報告しています。現在の出力は次のとおりです。

```text
A: epoll_pwait=-1 errno=Interrupted system call after 200 ms, handler ran 1, SIGUSR1 blocked after: yes
B: epoll_pwait=0, SIGUSR2 (marker) blocked after: no
```

## 実践への応用 / 考察

筆者の経験として残ったのは3点です。絞り込みは仮説を固定すること。観測の解像度は段階的に上げ、最後は時刻・ソース・最小再現で確定させること。報告の前に検索すること。今回は同日の報告に合流でき、議論を分散させずに済みました。

修正は2026年9月27日にmainへ（Junka, 2026a）、10月4日にstable/15へ入りました（Junka, 2026b）。15.2は11月6日にstable/15から分岐し、12月8日にRELEASE告知の予定なので（FreeBSD Project, 2026f）、15.2には収録される見込みです。一方、15.1向けのErrata Noticeは執筆時点で出ておらず、releng/15.1のソースは修正前のままです（FreeBSD Project, 2026b）。Bugzillaでは15.1への取り込みを求める声が出ており、バグは執筆時点でIn Progressです（FreeBSD Project, 2026e）。14系への反映は確認できていません。

15.1のまま使う場合は、第1部の版固定か、本記事の自前パッチになります。2.1.281も理論上は影響範囲にあること、自前パッチはpkgbaseの更新で上書きされること（筆者は更新のたびに置き換え直しています）に注意してください。Bugzillaでは `BUN_JSC_useConcurrentGC=0` が回避策として挙がっています（[Comment 12](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=298878#c12)、筆者は未検証）。

## まとめ

- 第2部の「アプリ側の競合」は誤りで、原因はLinuxulatorの `epoll_pwait`／`epoll_pwait2` が古いシグナルマスクを復元する不具合だった
- 決め手は、絞り込みをやめてメインの全システムコールを時刻順に読み、`epoll_pwait2` が `EINTR` ではなく0を返す行を見つけたこと
- 最小再現でLinuxとの差を確かめ、Bug 298878に合流した。修正はstable/15に入り、15.2に収録される見込み
- 15.1では、版の固定かパッチの自前適用でつなぐ

自分が公開した誤りは自分で訂正する。3部作を通して、それも観測と同じくらい大事な手順だと感じています。

## 参考文献

### 学術論文

本記事は技術トピックのため、査読付き論文ではなく、ソースコード・コミット・マニュアル・不具合報告といった一次資料を根拠としています。

### 公式ドキュメント

- Chagin, D. (2017). *Restore signal mask in epoll_pwait.*（commit 80c7315d17ce）. FreeBSD src. 2026年11月閲覧. https://github.com/freebsd/freebsd-src/commit/80c7315d17ce
- FreeBSD Project. (2026a). *kdump(1)*. FreeBSD Manual Pages（15.1-RELEASE）. 2026年11月閲覧. https://man.freebsd.org/cgi/man.cgi?query=kdump&sektion=1
- FreeBSD Project. (2026b). *sys/compat/linux/linux_event.c*（releng/15.1）. FreeBSD source. 2026年11月閲覧. https://cgit.freebsd.org/src/tree/sys/compat/linux/linux_event.c?h=releng/15.1
- FreeBSD Project. (2026c). *sys/kern/kern_sig.c*（releng/15.1）. FreeBSD source. 2026年11月閲覧. https://cgit.freebsd.org/src/tree/sys/kern/kern_sig.c?h=releng/15.1
- FreeBSD Project. (2026d). *sys/kern/sys_generic.c*（releng/15.1）. FreeBSD source. 2026年11月閲覧. https://cgit.freebsd.org/src/tree/sys/kern/sys_generic.c?h=releng/15.1
- FreeBSD Project. (2026e). *Bug 298878 - linux(4): epoll_pwait(2)/epoll_pwait2(2) with a sigmask leave a stale signal mask, deadlocking Bun apps (Claude Code, opencode)*. FreeBSD Bugzilla. 2026年11月閲覧. https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=298878
- FreeBSD Project. (2026f). *FreeBSD 15.2 Release Process*. 2026年11月閲覧. https://www.freebsd.org/releases/15.2R/schedule/
- Junka, G. (2026a). *linux(4): Fix signal mask restoration in epoll_pwait(2)/epoll_pwait2(2)*（commit 16a284b1cdfd、main）. FreeBSD src. 2026年11月閲覧. https://cgit.freebsd.org/src/commit/?id=16a284b1cdfd
- Junka, G. (2026b). *linux(4): Fix signal mask restoration in epoll_pwait(2)/epoll_pwait2(2)*（commit 0143078248bb、stable/15）. FreeBSD src. 2026年11月閲覧. https://cgit.freebsd.org/src/commit/?id=0143078248bb
- Linux man-pages project. (2026). *epoll_wait(2)*（man-pages 6.19）. 2026年11月閲覧. https://man7.org/linux/man-pages/man2/epoll_wait.2.html

### Web記事

- Tachi, Y. (2026a). Comment on Issue #96931（第2部の仮説の訂正）. GitHub. 2026年11月閲覧. https://github.com/anthropics/claude-code/issues/96931#issuecomment-5847154102
- Tachi, Y. (2026b). Comment on Issue #96931（FreeBSD Bug 298878への誘導）. GitHub. 2026年11月閲覧. https://github.com/anthropics/claude-code/issues/96931#issuecomment-5850598490
