---
title: FreeBSD上のClaude Codeが応答のあと固まる（1）――「固まった」を観測で分け、版を固定する
description: FreeBSD 15.1（arm64）のLinuxulator上で動かしていたClaude Code
  2.1.283が、応答の直後からキー入力を受け付けなくなりました。「固まった」を、プロセスが死んだ・入力が切り離された・処理が詰まった・スレッドが眠った、の4つに分けて観測し、psとprocstatでメインスレッドがfutexで眠り続けていると確定するまでの記録です。回避策として、公式インストーラが弾くFreeBSDでも本体のclaude
  installで2.1.281に戻し、DISABLE_AUTOUPDATERで固定する手順を示します。3部作の第1部です。
pubDate: 2026-10-30T06:00:00.000+09:00
author: Yuki Tachi
tags:
  - FreeBSD
  - Linuxulator
  - Claude Code
  - トラブルシューティング
  - procstat
draft: false
---

## はじめに

返事は来た。でも次のプロンプトが打てない――2026年9月26日、筆者のFreeBSD機でClaude Codeがこの状態になりました。応答の表示までは正常で、その直後からキー入力が一切反映されません。

「固まった」は、症状の説明としてはほとんど何も言っていません。プロセスが死んだのか、入力だけが切り離されたのか、CPUを使い切って詰まっているのか、どこかで眠っているのか。どれかによって、次に見るべき場所がまったく違います。

本記事は3部作の第1部です。「固まった」を観測で4つに分ける手順と、原因が分かる前に回避策（版の固定）を確保する運用を扱います。この部だけで回避策までは持ち帰れる構成にしています。なお、このブログ自体がFreeBSD上のClaude Codeで下書きされています（仕組みは「[この記事はAIが自動生成しています](/blog/2026-06-19-この記事はaiが自動生成していますnotionclaude-codefreebsdのブログ自動生成/)」参照）。

## 背景・課題

構成は次のとおりです。

```text
WezTerm → WSL → ssh → FreeBSD 15.1-RELEASE-p2 (arm64) 上の tmux → Claude Code
```

Claude Codeの公式の対応OSは macOS・Windows・Ubuntu・Debian・Alpine Linux で、FreeBSDは含まれません（Anthropic, 2026a）。それでも動くのは、FreeBSDのLinuxバイナリ互換機能、通称Linuxulatorのおかげです。これは改変なしのLinuxバイナリを実行する仕組みで、Linuxのプログラムも通常のFreeBSDプロセスとして動き、いつもの方法でトレースやデバッグができます（FreeBSD Project, 2026a）。ユーザーランドは `linux_base-rl9`（Rocky Linux 9ベース）を使っています。15.1への更新手順は「[pkgbase時代のFreeBSDアップグレード実践](/blog/2026-06-20-pkgbase時代のfreebsdアップグレード実践awsで150から151へ/)」に書きました。

FreeBSDのバグ報告によれば、ネイティブ版のClaude CodeはBunでビルドされたLinuxバイナリです（FreeBSD Project, 2026d）。手元でも `file` で確かめると `ELF 64-bit LSB executable, ARM aarch64 ... for GNU/Linux` と出ます。

課題は2つありました。原因を突き止める前に仕事を再開できる状態に戻すこと、そして「固まった」の正体を推測ではなく観測で確定することです。

## 本論

### 既知の不具合を探す

まずissueを探しました。GitHubの #96931 は2026年9月25日起票で、2.1.282以降、対話セッションが0〜90秒でキー入力を受け付けなくなり、2.1.281に戻すと直る、という報告です。環境はFreeBSD 15.1-RELEASEのLinuxulatorで、プロセスは生きたままCPU約0%とされています（kharluu76, 2026）。別の利用者も、FreeBSD 15.0の環境で2.1.281に戻して使っていると報告していました。

手元の2.1.283でも再現しました。筆者はFreeBSDの版、`linux_base` の版、端末構成、arm64であることを揃えて同じissueに追記しています。環境情報を揃えて書くのは、「自分も」だけのコメントより切り分けに役立つからです。

### ログの誤読――「ヒットした」と「その時点で起きた」は別物

次に `--debug` を付けて起動し、ログを探しました。筆者の環境ではセッションごとのログが `~/.claude/debug/` に書かれます（公式リファレンスが明示しているのは `--debug` と `--debug-file` の存在までです：Anthropic, 2026b）。

`grep` すると、issueに書かれていた行がそのままヒットしました。

```text
[DEBUG] prompt.edit: unhooked; the composer relays nothing
```

「同じバグだ」と判断しかけましたが、これは誤りでした。行番号を見ると、調べた2つのログでは、いずれも起動直後（5行目と114行目）に出ていました。起動時に毎回出る行で、固まった瞬間の記録ではありません。issueの起票者自身も、この行は毎回起動時に出るので引き金ではないかもしれない、と注記していました（kharluu76, 2026）。しかも筆者が開いていたのは、正常終了した別セッションのログでした。

`grep` のヒットは「その文字列がある」ことしか示しません。時刻と行番号、そしてどのセッションのログかを確かめて、初めて「その時点で起きた」と言えます。

### 何が止まっているかを4つに分ける

「固まった」を次の4つに分けて観測します。

| 分類 | プロセス | CPU | 見るべきもの |
|------|----------|-----|--------------|
| 死んだ | 存在しない／ゾンビ | — | `ps` に出るか |
| 入力が切り離された | 生存 | 低い | ログは流れるが、キー入力だけ記録されない |
| 詰まった | 生存 | 高い | 描画や書き込みが続いている |
| 眠った | 生存 | ほぼ0 | どのスレッドが何を待っているか |

1つ目の確認は、`tail -f` でログを流しながらキーを押すことです。何も記録されませんでした。「入力が切り離された」なら他の処理のログは流れ続けるはずなので、この時点で眠っている可能性が高くなります。

次に `ps` です。

```sh
ps -o pid,stat,%cpu,wchan -p <pid>
```

結果はSTAT `I+`、CPU 0%、WCHANは `futex` でした。`I` は約20秒を超えて眠っているプロセス、`+` は制御端末の前面プロセスグループにいることを示します（FreeBSD Project, 2026b）。

最後に、スレッドごとのカーネルスタックを見ます。`procstat -k` はプロセス内のスレッドのカーネルスタックを表示し、`-k` を重ねると関数のオフセットも出ます（FreeBSD Project, 2026c）。

```sh
procstat -kk <pid>
```

メインスレッドの行だけ抜粋します。

```text
mi_switch sleepq_catch_signals sleepq_wait_sig _sleep umtxq_sleep linux_sys_futex do_el0_sync handle_el0_sync
```

メインスレッドはイベントループ（epoll）ではなく、`linux_sys_futex` でタイムアウトなしに眠っていました。他のスレッドは futex・ppoll・epoll・inotify の待ちで、いずれもアイドルです。分類は「眠った」で確定です。

対照的なのが #25286 です。macOSでの報告で、フリーズ中も端末描画が全画面書き込みを繰り返しており（davidpmclaughlin, 2026）、別の利用者は影響を受けたセッションで約35%のCPU使用と継続的な書き込みを観測しています（shinglokto, 2026）。これは「詰まった」型です。同じ「入力を受け付けない」でも、CPUとスタックを見れば別物だと分かります。

## 実践への応用 / 考察

### 公式インストーラは使えない、本体の `claude install` は使える

回避策は2.1.281への切り戻しです。公式の手順どおりインストールスクリプトに版を渡そうとすると、FreeBSDでは次のエラーで止まります。

```text
Unsupported operating system: FreeBSD. See https://code.claude.com/docs for supported platforms.
```

スクリプトは `uname -s` の結果が Darwin か Linux でなければ、この時点で終了します（Anthropic, 2026c）。一方、本体の `claude install` は版の指定を受け付けます（Anthropic, 2026b）。

```sh
claude install 2.1.281
claude --version   # 2.1.281 (Claude Code)
```

実はスクリプト自身も、最後はダウンロードした本体に `claude install <版>` を実行させる作りです（Anthropic, 2026c）。つまり版の切り替えそのものは本体の `claude install` が担っており、すでに入っている本体から直接呼べば、スクリプトのOS判定を通らずに済みます。本体はLinuxulator上でLinuxバイナリとして動くので、FreeBSDでもそのまま実行できます。

### 自動更新を止め、調査用の版は別に起動する

`~/.local/bin/claude` は `~/.local/share/claude/versions/` 配下へのシンボリックリンクで（Anthropic, 2026a）、旧版もそこに残っています。自動更新は `~/.claude/settings.json` の `env` で止めます。

```json
{
  "env": { "DISABLE_AUTOUPDATER": "1" }
}
```

公式ドキュメントでは、これはバックグラウンドの更新確認だけを止め、`claude install` は引き続き使えるとされています（Anthropic, 2026a）。issueの起票者によれば、`autoUpdates: false` だけでは数分で新版に再リンクされ、`DISABLE_AUTOUPDATER` で止まったそうです（kharluu76, 2026）。

調査中も既定版は2.1.281のままにし、問題の版は `~/.local/share/claude/versions/2.1.283` を直接起動します。仕事用と観測用を分けておけば、再現実験のたびに環境を壊さずに済みます。

### 版の固定は応急処置にすぎない

ここは強調しておきます。FreeBSDのBug 298878とその修正コミットによれば、影響を受けるのはClaude Code 2.1.269以降で、原因はLinuxulator側（`linux64.ko`）にあります（FreeBSD Project, 2026d, 2026e）。amd64で修正を確認した利用者も、2.1.281は頻度が低いだけで同じ問題を抱えているはずだと書いています（FreeBSD Project, 2026d）。2.1.281への固定は発生頻度を下げる手当てで、根本的な修正はカーネル側です。この修正は2026年9月27日にFreeBSDのmainブランチへコミット済みで、コミットメッセージによればstable/15へは約1週間後に取り込まれる予定です（FreeBSD Project, 2026e）。詳細は第3部で扱います。

## まとめ

- 「固まった」は、死んだ・入力が切り離された・詰まった・眠った、の4つに分けて観測する
- ログの `grep` ヒットは「その時点で起きた」証拠ではない。行番号・時刻・セッションを確かめる
- `ps -o stat,%cpu,wchan` で大枠を、`procstat -kk` でスレッドが何を待っているかを確定する
- FreeBSDでは公式インストーラは弾かれるが、本体の `claude install <版>` で切り戻せる。固定は `DISABLE_AUTOUPDATER`
- 版の固定は応急処置。本当の修正はLinuxulator側にあり、FreeBSDのmainでは修正済み

次回（第2部）は、メインスレッドが「なぜ」futexで眠ったままになったのかを、ktraceとDTraceで追います。

## 参考文献

### 学術論文

本記事は技術トピックのため、査読付き論文ではなく、公式ドキュメント・マニュアル・不具合報告といった一次資料を根拠としています。

### 公式ドキュメント

- Anthropic. (2026a). *Advanced setup*. Claude Code Docs. 2026年9月閲覧. https://code.claude.com/docs/en/setup
- Anthropic. (2026b). *CLI reference*. Claude Code Docs. 2026年9月閲覧. https://code.claude.com/docs/en/cli-reference
- Anthropic. (2026c). *install.sh*（Claude Code インストールスクリプト）. 2026年9月閲覧. https://claude.ai/install.sh
- FreeBSD Project. (2026a). *Chapter 12. Linux Binary Compatibility*. FreeBSD Handbook. 2026年9月閲覧. https://docs.freebsd.org/en/books/handbook/linuxemu/
- FreeBSD Project. (2026b). *ps(1)*. FreeBSD Manual Pages（15.1-RELEASE）. 2026年9月閲覧. https://man.freebsd.org/cgi/man.cgi?query=ps&sektion=1
- FreeBSD Project. (2026c). *procstat(1)*. FreeBSD Manual Pages（15.1-RELEASE）. 2026年9月閲覧. https://man.freebsd.org/cgi/man.cgi?query=procstat&sektion=1
- FreeBSD Project. (2026d). *Bug 298878 - linux(4): epoll_pwait(2)/epoll_pwait2(2) with a sigmask leave a stale signal mask, deadlocking Bun apps (Claude Code, opencode)*. FreeBSD Bugzilla. 2026年9月閲覧. https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=298878
- FreeBSD Project. (2026e). *linux(4): Fix signal mask restoration in epoll_pwait(2)/epoll_pwait2(2)*（commit 16a284b1cdfd）. 2026年9月閲覧. https://cgit.freebsd.org/src/commit/?id=16a284b1cdfd45ba99c2723e7f88497e76b235ad

### Web記事

- davidpmclaughlin. (2026). *Claude Code freezes/hangs with no input accepted — 100% write ratio in terminal renderer*（Issue #25286）. GitHub. 2026年9月閲覧. https://github.com/anthropics/claude-code/issues/25286
- kharluu76. (2026). *[Bug] Input box stops accepting keystrokes in 2.1.282 after 0-90 seconds into session*（Issue #96931）. GitHub. 2026年9月閲覧. https://github.com/anthropics/claude-code/issues/96931
- shinglokto. (2026). Comment on Issue #25286. GitHub. 2026年9月閲覧. https://github.com/anthropics/claude-code/issues/25286#issuecomment-4162092381
