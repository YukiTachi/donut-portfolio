---
title: FreeBSD上のClaude Codeが応答のあと固まる（2）――ktraceとDTraceでカーネル側から追う
description: Linuxulator上で固まったClaude Code
  2.1.283を、FreeBSD側の道具だけで追いました。ktraceでfutexとシグナルを記録し、メインスレッドと別スレッドの相互待ち、保留されたままブロックされたSIGPWR、DTraceで見えたマスク操作の3段パターンまでを観測した記録です。この時点で立てた「アプリ側の手順上の競合」という仮説と、それが誤りだったことまでを扱う3部作の第2部です。
pubDate: 2026-11-13T06:00:00.000+09:00
author: Yuki Tachi
tags:
  - FreeBSD
  - Linuxulator
  - Claude Code
  - DTrace
  - ktrace
  - トラブルシューティング
draft: false
---

## はじめに

[第1部](/blog/2026-09-29-freebsd上のclaude-codeが応答のあと固まる1固まったを観測で分け版を固定する/)では、FreeBSD 15.1（arm64）のLinuxulator上でClaude Code 2.1.283が固まったとき、メインスレッドが `linux_sys_futex` でタイムアウトなしに眠り続けていることまでを確かめました。残った問いは「なぜ誰もメインを起こさないのか」です。

本記事は3部作の第2部です。ktrace・procstat・DTraceで、Linuxバイナリのスレッドが何を待ち、どのシグナルがどこで止まっているかをカーネル側から追います。先に書くと、この部の最後に立てた仮説は誤りでした。そこに至る観測の過程を、そのまま記録します。

## 背景・課題

Linuxulatorは改変なしのLinuxバイナリを通常のFreeBSDプロセスとして動かすため、FreeBSDのトレース道具がそのまま使えます（第1部参照）。ただし見えるのはLinuxのシステムコール番号やシグナル番号をFreeBSD側に写した姿なので、読むには対応表が要ります。

課題は2つありました。仕事用の環境（既定版は2.1.281に固定済み）を壊さずに観測すること、そしてトークンや会話の中身を記録に残さないことです。

## 本論

### 記録の取り方

問題の版はインストール先のファイルを直接起動し、ktraceの下で動かしました。

```sh
ktrace -f ~/cc.ktr -t cs ~/.local/share/claude/versions/2.1.283 --debug
```

`-t` は記録する種類の指定で、`c` はシステムコール、`s` はシグナル処理です（FreeBSD Project, 2026a）。入出力の中身（`i`）は記録しないので、送受信したトークンや会話はファイルに残りません。子プロセスへ追跡を引き継ぐ `-i` も付けていません。固まったら、止める前に `procstat -kk` と `procstat -j` の出力を保存します。読むときは `kdump -H -T` で、スレッドID（tid）と絶対時刻を付けて表示します（FreeBSD Project, 2026b）。

以下の抜粋では、PIDを例示値（12345）に置き換え、時刻は秒の下位桁だけを残しています。

### futexを読む

Linuxのfutexはスレッド間の待ち合わせに使うシステムコールで、第2引数が操作コードです。0x80は `FUTEX_PRIVATE_FLAG`、0x100は `FUTEX_CLOCK_REALTIME` に当たります（各フラグの意味はLinux man-pages project, 2026a。数値はカーネルの `include/uapi/linux/futex.h` の定義）。読み方は次のとおりです。

| 操作コード | 意味 |
|------------|------|
| 0x80 | WAIT（プロセス内専用） |
| 0x81 | WAKE（プロセス内専用） |
| 0x189 | WAIT_BITSET（プロセス内専用・CLOCK_REALTIME） |

`WAIT_BITSET` は第4引数（タイムアウト）がNULLなら無期限に待ち、第6引数の0xffffffffは「どの起こし手でもよい」という意味です（Linux man-pages project, 2026b）。

まず、futexのエミュレーション自体が壊れていないかを見ました。JSCWarmUpというスレッドはタイムアウト付きのWAITを繰り返し、別スレッドのWAKEで起こされていました。起こし役は序盤がメイン、固まった後はWaitpidスレッドで、固まっている最中もこの往復は正常に続いていました。

### 相互待ちを見つける

次に、メインが最後に眠ったアドレスを追いました。メインと「HTTP Client」と表示されたスレッドの間に、規則正しい往復があります。

```text
186043 2.1.283     003.985787 CALL linux_sys_futex(0x3de9a362ce0,0x189,0xcc,0,0,0xffffffff)
197984 HTTP Client 003.985806 CALL linux_sys_futex(0x3de9a362ce0,0x81,0x1,...)
186043 2.1.283     005.060721 CALL linux_sys_futex(0x3de9a362ce0,0x189,0xce,0,0,0xffffffff)
```

メインが期待値を2ずつ増やしながら待ち、相手がWAKEで起こす。その最後の回（0xce）だけ、WAKEが来ません。

ここで注意があります。「HTTP Client」はktraceが表示したスレッド名にすぎず、役割の証拠ではありません。後述のコラムのとおり、Linuxulator上ではスレッド名の扱い自体に怪しい点がありました。筆者はユーザー空間のスタックを取っていません。FreeBSDのBug 298878の報告者はユーザー空間スタックから、メインはJavaScriptCore（JSC、BunのJavaScriptエンジン）のヒープ処理の中でGCを待つ `pthread_cond_wait()`、相手はJSCのヒープ側スレッドで `pthread_kill()` 直後の `sem_wait()` にいる、と特定しています（FreeBSD Project, 2026i）。

その相手の最後の動きがこれです。

```text
197984 HTTP Client 005.060637 CALL linux_rt_sigprocmask(SIG_BLOCK,...)
197984 HTTP Client 005.060680 CALL linux_tgkill(12345,12345,SIGPWR)
197984 HTTP Client 005.060694 CALL linux_rt_sigprocmask(SIG_SETMASK,...)
197984 HTTP Client 005.060701 CALL linux_sys_futex(0x565c880,0x189,0,0,0,0xffffffff)
```

メインにSIGPWRを送り、別のアドレスで無期限に待っています。同じセッションの序盤には、fs.watchと表示されたスレッドが同じ手順を4回行い、メインはそのたびに16〜39マイクロ秒でシグナルを受け取っていました。そのうち3回は、送り手が0x565c880で待ち、メインがシグナルを受け取ってから11〜27マイクロ秒でWAKEして起こしています（残る1回は、futexでの待ちが記録されていません）。「SIGPWRで呼びかけ、ハンドラの応答を待つ」ハンドシェイクです。メインは相手のWAKEを待ち、相手はメインのハンドラの応答を待つ。ここで輪が閉じます。

### 届いたのか、塞がれたのか

kdumpはこのシグナルを `SIGRT33` と表示します。LinuxulatorはFreeBSDにないSIGPWRを `LINUX_SIGPWREMU` に写しており、定義は `SIGRTMIN + (LINUX_SIGRTMAX - LINUX_SIGRTMIN) + 1`、つまり65 + 32 + 1 = 98番です（FreeBSD Project, 2026e）。98番はSIGRTMIN（65）から数えて33番目なので `SIGRT33` になります。

固まった状態の `procstat -j` では、メインの98番だけが `PB` でした。

```text
12345 186043 ollector Thread  98       PB
```

`P` はスレッドに保留中、`B` はスレッドのシグナルマスクでブロック中を示します（FreeBSD Project, 2026c）。届いてはいるが、塞がれている状態です。

「メインがハンドラの中で止まっているのでは」という線も確かめました。awkでメインの `PSIG`（ハンドラ起動）と `rt_sigreturn`（ハンドラからの復帰）を数え、入れ子の深さを追います。

```sh
kdump -H -f ~/cc.ktr | awk '
$2==186043 && $4=="PSIG" && /caught/ {d++; print NR": enter "$5" depth="d}
$2==186043 && $4=="RET" && $5=="linux_rt_sigreturn" {d--; print NR": return depth="d}'
```

SIGPWRのハンドラが入れ子になる深さ2は観測されましたが、毎回0に戻っていました。固まった時点のメインはハンドラの外にいます。

### DTraceでマスクの変化を見る

では誰がメインの98番をブロックしたのか。fbtプロバイダはカーネル関数の入口と出口に探針を置けます（FreeBSD Project, 2026d）。マスク変更を担う `kern_sigprocmask` を狙いました。

最初は「98番の状態が変わった瞬間だけ」を記録するスクリプトにしましたが、これは状態を変えない呼び出し（後述の3段パターンの2段目のようなもの）を記録しない作りで、前後関係が読めませんでした。そこで全呼び出しを記録し直しました。

```sh
sudo dtrace -q -p <pid> -n '
fbt::kern_sigprocmask:entry
/pid == $target/
{
  self->in = 1;
  self->how = arg1;
  self->flags = arg4;
  self->set98 = arg2 ? ((((sigset_t *)arg2)->__bits[3] >> 1) & 1) : -1;
  self->before = (curthread->td_sigmask.__bits[3] >> 1) & 1;
}
fbt::kern_sigprocmask:return
/self->in/
{
  printf("%d tid=%d how=%d flags=%x set98=%d before=%d after=%d\n",
    timestamp, curthread->td_tid, self->how, self->flags,
    self->set98, self->before, (curthread->td_sigmask.__bits[3] >> 1) & 1);
  self->in = 0;
}'
```

`sigset_t` は32ビット×4語で、シグナル番号nは `(n-1) >> 5` 語目の `1 << ((n-1) & 31)` ビットです（FreeBSD Project, 2026g）。98番なら `__bits[3]` の0x2になります。`how` の1は `SIG_BLOCK`、3は `SIG_SETMASK` です（FreeBSD Project, 2026h）。

メインは普段「SIGPWR込みのマスクを設定→内側で再設定→SIGPWR抜きに戻す」という3段で動いていました。固まった回（スレッドIDはktraceの回とは別）はこうです。

```text
tid=198180 how=1 set98=1 before=0 after=1   # 送り手、tgkillの前
tid=198180 how=3 set98=0 before=1 after=0   # 送り手、tgkillの後
tid=198082 how=3 set98=1 before=0 after=1   # メインがSIGPWRをブロック
tid=198082 how=3 set98=1 before=1 after=1   # 2段目。3段目は来ない
```

送り手がマスクを戻してから約32マイクロ秒後に、メインが98番をブロックし、そのまま戻しませんでした。

### この時点の仮説

筆者はこれを「アプリ（ランタイム）がSIGPWRをブロックした区間で他スレッドを待つ、手順上の競合」と読みました。シグナルがメインに配送される前にメインがマスクで塞ぐと、両者が永久に待つ、という筋書きです。2026年9月26日、この仮説をissue #96931に英文で投稿しています（Tachi, 2026）。

### コラム：プロセス名が「ollector Thread」になっていた

`procstat` のCOMM欄がすべて「ollector Thread」でした。LinuxulatorのPR_SET_NAMEの処理を読むと、名前をスレッドではなくプロセスの `p_comm` に書き込んでいます。長さはLinuxと同じ16バイト（終端を含む）に収められます（FreeBSD Project, 2026f）。JSCのGCスレッドが自分の名前（「…Collector Thread」の末尾15文字）を設定し、それがプロセス名になったと筆者は推定しています。GCスレッド自身のTDNAMEは空（`-`）でした。フリーズとは別の副次的な痕跡ですが、スレッド名を役割の証拠にしなかった理由でもあります。

## 実践への応用 / 考察

LinuxulatorのLinuxバイナリでも、システムコール・シグナル・スレッドごとのマスクは、FreeBSD側から直接観測できます。筆者の経験では、効いたのは「同じアドレスを誰が待ち、誰が起こすか」を往復として並べることでした。輪が閉じた瞬間に、問題は「シグナルがなぜ塞がれたか」に絞られます。

一方で、観測が揃うほど解釈を急ぎたくなります。今回のDTraceが示したのは「メインのスレッドで `kern_sigprocmask` が呼ばれ、98番がブロックされた」という事実だけです。誰がその呼び出しを起こしたのかは、このスクリプトでは区別できていませんでした。

## まとめ

- ktraceは `-t cs` にすると、会話やトークンを残さずにシステムコールとシグナルを記録できる
- futexは操作コード（0x80・0x81・0x189）を読み、同じアドレスの往復を並べると相互待ちが見える
- kdumpの `SIGRT33` はLinuxulator上のSIGPWR（98番）。`procstat -j` の `PB` で「届いたが塞がれた」と分かる
- DTraceのfbtで `kern_sigprocmask` を見ると、3段パターンの3段目が来ないことが分かった

ただし、この仮説は誤りでした。`kern_sigprocmask` はアプリの呼び出しだけでなく、カーネルの内部からも呼ばれます。そしてktraceを読むときの `grep` の絞り込みが、あるシステムコールを視界から外していました。何を見落としていたのかは、第3部で扱います。

## 参考文献

### 学術論文

本記事は技術トピックのため、査読付き論文ではなく、マニュアル・ソースコード・不具合報告といった一次資料を根拠としています。

### 公式ドキュメント

- FreeBSD Project. (2026a). *ktrace(1)*. FreeBSD Manual Pages（15.1-RELEASE）. 2026年10月閲覧. https://man.freebsd.org/cgi/man.cgi?query=ktrace&sektion=1
- FreeBSD Project. (2026b). *kdump(1)*. FreeBSD Manual Pages（15.1-RELEASE）. 2026年10月閲覧. https://man.freebsd.org/cgi/man.cgi?query=kdump&sektion=1
- FreeBSD Project. (2026c). *procstat(1)*. FreeBSD Manual Pages（15.1-RELEASE）. 2026年10月閲覧. https://man.freebsd.org/cgi/man.cgi?query=procstat&sektion=1
- FreeBSD Project. (2026d). *dtrace_fbt(4)*. FreeBSD Manual Pages（15.1-RELEASE）. 2026年10月閲覧. https://man.freebsd.org/cgi/man.cgi?query=dtrace_fbt&sektion=4
- FreeBSD Project. (2026e). *sys/compat/linux/linux.c*（releng/15.1）. FreeBSD source. 2026年10月閲覧. https://cgit.freebsd.org/src/tree/sys/compat/linux/linux.c?h=releng/15.1
- FreeBSD Project. (2026f). *sys/compat/linux/linux_misc.c*（releng/15.1）. FreeBSD source. 2026年10月閲覧. https://cgit.freebsd.org/src/tree/sys/compat/linux/linux_misc.c?h=releng/15.1
- FreeBSD Project. (2026g). *sys/sys/_sigset.h*（releng/15.1）. FreeBSD source. 2026年10月閲覧. https://cgit.freebsd.org/src/tree/sys/sys/_sigset.h?h=releng/15.1
- FreeBSD Project. (2026h). *sys/sys/signal.h*（releng/15.1）. FreeBSD source. 2026年10月閲覧. https://cgit.freebsd.org/src/tree/sys/sys/signal.h?h=releng/15.1
- FreeBSD Project. (2026i). *Bug 298878 - linux(4): epoll_pwait(2)/epoll_pwait2(2) with a sigmask leave a stale signal mask, deadlocking Bun apps (Claude Code, opencode)*. FreeBSD Bugzilla. 2026年10月閲覧. https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=298878
- Linux man-pages project. (2026a). *futex(2)*（man-pages 6.19）. 2026年10月閲覧. https://man7.org/linux/man-pages/man2/futex.2.html
- Linux man-pages project. (2026b). *FUTEX_WAIT_BITSET(2const)*. 2026年10月閲覧. https://man7.org/linux/man-pages/man2/FUTEX_WAIT_BITSET.2const.html

### Web記事

- Tachi, Y. (2026). Comment on Issue #96931（ktrace・DTraceによる追跡結果の投稿）. GitHub. 2026年10月閲覧. https://github.com/anthropics/claude-code/issues/96931#issuecomment-5846985029
