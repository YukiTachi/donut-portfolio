---
title: 本番APIをPoetry移行する――Python 3.13・systemd・ブランチ戦略の実践
description: 本番稼働中のFlask
  APIをvenv+requirements.txtからPoetryへ移行しました。systemd経由でpoetry
  runを叩いてPermission
  deniedに遭い、当初疑ったPrivateTmpは一次資料に当たると無関係だと判明します。ラッパースクリプトによる解決、package-mode =
  falseの意味、Gemini→Claude APIへの依存入れ替えでパッケージ数が48から38に減った経緯、そして開発環境の移行が遅れている状況でのproductionブランチ戦略までを実録でまとめます。
pubDate: 2026-08-23T19:12:00.000+09:00
author: Yuki Tachi
tags:
  - Poetry
  - Python
  - systemd
  - CentOS Stream 9
  - デプロイ
draft: true
---

## はじめに

`requirements.txt` と `venv` の組み合わせは、動いてはいます。ただ「動いている」と「同じ環境をもう一度作れる」は別の話です。ピン留めが甘ければ再構築のたびに解決結果が変わりますし、直接依存と推移的依存の区別もファイルからは読み取れません。

本記事では、本番稼働中の Flask API を、サービスを止めずに Poetry へ移行した工程を実録として辿ります。中心に置くのは、systemd から Poetry を起動したときに踏んだ落とし穴、依存パッケージを大幅に入れ替える作業の管理、そして開発環境の移行が遅れている状況でのブランチ戦略の3点です。なお実値(ドメイン・API キーなど)は汎用化しています。

## 背景・課題

移行対象の構成は次のとおりです。

- OS: CentOS Stream 9(KUSANAGI 環境に相乗り)
- 構成: nginx → gunicorn → Flask のリバースプロキシ構成
- Python: システム標準の 3.9 から、pyenv で入れた 3.13 へ
- 依存管理: `requirements.txt` + `venv` から Poetry + `pyproject.toml` へ

Python のバージョンを上げる動機ははっきりしています。Python 3.9 は 2020 年 10 月リリースで、アップストリームでは 2025 年 10 月 31 日にサポートが終了しました(Python Software Foundation, 2026)。一方 Python 3.13 は 2024 年 10 月リリースで、サポート終了予定は 2029 年 10 月です。

ただし注釈が要ります。RHEL 9 系では Python 3.9 が BaseOS の非モジュラー RPM として提供され、**RHEL 9 のライフサイクル全体を通じてサポートされます**(Red Hat, 2026)。バックポートがある以上、システム Python 3.9 が即座に危険というわけではありません。それでもライブラリの対応状況を考えると、アプリケーション側は自前で新しい処理系を持つほうが素直です。

依存管理を Poetry にする理由は再現性です。`poetry.lock` があるとき `install` は「`pyproject.toml` に列挙した依存を解決しつつ、バージョンは `poetry.lock` の正確な値を使う」ため、関係者全員が同じバージョンを使うことが保証されます(Poetry, 2026a)。手管理の `requirements.txt` で一番不安だったのが、この一貫性でした。

## 本論

### systemdからPoetryを起動する――Permission deniedの正体

まず systemd ユニットを書き換えます。仮想環境の gunicorn を直接指していた `ExecStart` を `poetry run` 経由に変えました。

```ini
[Service]
ExecStart=/home/appuser/.local/bin/poetry run gunicorn -c gunicorn.conf.py app:app
```

結果は `Permission denied` で起動失敗。最初に疑ったのは `PrivateTmp=true` で、「セキュリティ機能がホームディレクトリを隠しているのではないか」という見立てでした。

**この見立ては誤りでした。** `PrivateTmp=` が隔離するのは `/tmp/` と `/var/tmp/` だけで、ホームディレクトリには関与しません(systemd, 2026a)。ホームを不可視にするのは `ProtectHome=` のほうで、真のとき「`/home/`、`/root`、`/run/user` がアクセス不能かつ空になる」と明記されています(既定はどちらも無効)。

実際の原因は2つの組み合わせでした。ひとつは、systemd が `ExecStart` をシェル経由で実行しないこと(systemd, 2026b)。pyenv は「shims のディレクトリを PATH の先頭に挿入する」ことで動作するため(pyenv, 2026)、シェル初期化のない文脈では前提が崩れます。もうひとつは、サービス実行ユーザーからホーム配下(既定では他ユーザーが辿れない)の `poetry` へ到達できないことでした。

解決策はラッパースクリプトです。システムパス上に置き、その中で初期化を済ませてから `poetry run` を呼びます。

```bash
#!/bin/bash
# /opt/example-api/start.sh
export PYENV_ROOT="/home/appuser/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
cd /opt/example-api
exec /home/appuser/.local/bin/poetry run gunicorn -c gunicorn.conf.py app:app
```

ユニット側は `ExecStart=/opt/example-api/start.sh` に単純化されます。`exec` は systemd のシグナルを gunicorn へ直接届けるためです。なお本構成のように nginx を前段に置く場合の補足として、gunicorn が `X-Forwarded-*` を既定で信頼するのは接続元が localhost のときだけです(Gunicorn, 2026)。

### package-mode = false――アプリはパッケージではない

次に `poetry install` が README.md まわりのエラーで止まります。原因は既定動作でした。パッケージモードでは「`poetry install` の実行時にプロジェクト自体が editable モードでインストールされる」ため、パッケージとしてのメタデータが要求されます(Poetry, 2026a)。

Flask アプリは PyPI に公開しません。依存管理だけに使いたいので非パッケージモードを選びます。

```toml
[tool.poetry]
package-mode = false
```

これは「Poetry を依存管理だけに使いパッケージングには使わない場合」のための設定で、`poetry install` はプロジェクト自体を入れず依存だけを入れます(`--no-root` と同じ挙動)(Poetry, 2026a; Poetry, 2026c)。

### 依存の大幅入れ替えをPoetryで管理する

移行と並行して、生成部分を Gemini API から Claude API へ切り替える変更が入りました。`requirements.txt` 上では Google 関連 12 個の削除と `anthropic` の追加という差分です。

Poetry では直接依存だけを操作します。

```bash
poetry add anthropic
poetry remove google-api-python-client google-generativeai
```

`add` は「必要なパッケージを `pyproject.toml` に追加してインストールする」コマンドです(Poetry, 2026b)。ここで効いたのがロックファイルによる解決でした。直接依存を2つ外しただけで、他から要求されなくなった推移的依存 17 個が道連れに消えました。`anthropic` とその依存 8 個の追加を差し引いて、`poetry.lock` のパッケージ数は 48 から 38 へ(数値はロックファイルのgit履歴から実測)。手管理の `requirements.txt` なら、この 17 個は消し忘れて残る負債になっていたはずです。

なお `remove` の説明に推移的依存の扱いは明記されていません。環境をロックファイルと厳密に一致させたいなら、「`poetry.lock` に追跡されていないパッケージを追加で削除する」と明記された `sync` のほうが意図が明確です(Poetry, 2026b)。

### productionブランチ戦略――開発環境の移行が遅れているとき

ここが運用上いちばん悩んだ部分です。本番は Python 3.13 + Poetry に移りましたが、開発環境はまだ 3.9 + `requirements.txt` のままで、`pyproject.toml` と `poetry.lock` を `main` に直接マージすると `develop` 側の開発を巻き込んでしまいます。

採った現実解は、`main` から `production` ブランチを切り、Poetry 関連の設定を `production` にだけ置く方式です。本番デプロイは次の手順になります。

```bash
git checkout production
git merge origin/main          # アプリケーションコードを取り込む
git diff HEAD@{1} -- requirements.txt   # 依存の差分を確認
poetry add <追加されたパッケージ>          # 差分をPoetry側へ反映
```

依存の変更を人間が読む工程は手間です。ただ移行期間中の二重管理は避けられず、暗黙にするよりブランチとして可視化するほうが安全でした。恒久策ではなく、開発環境の移行完了時に `main` へマージして畳む前提の構成です。

### APIキーの分離

開発と本番で API キーを分けました。鍵の漏洩範囲を分離でき、コストと使用量を環境ごとに追えるためです。`.env` はパーミッション 600 とし `.gitignore` に登録、systemd からは `EnvironmentFile=` で読ませ、ユニット内に値を直書きしません(systemd, 2026a)。なお `anthropic` は移行時点で 0.75.0(2025 年 11 月 24 日公開)を使いました。2026 年 8 月 20 日に 1.0.0 が出ているため、これから移行するならメジャーバージョンの差分確認が要ります(Python Package Index, 2026)。

## 実践への応用

今回の作業から一般化できることを3つ挙げます。

第1に、**systemd のセキュリティ設定は名前から機能を推測しない**。`PrivateTmp=` と `ProtectHome=` は名前が似ていて、症状(Permission denied)も見分けがつきません。man ページで既定値と作用範囲を確認する数分が、当てずっぽうの試行より速いというのが実感です。

第2に、**開発者向けツールのパスは systemd から見えない前提で設計する**。pyenv も Poetry もシェル初期化とホームディレクトリを前提にしていますが、systemd はどちらも与えません。ラッパースクリプトを1枚挟むのは遠回りに見えて、「シェル前提の世界」と「シェルなしの世界」の境界を1ファイルに閉じ込める設計になります。

第3に、**移行タイミングのずれはブランチで表現する**。本番と開発の移行が同時に進まないのはよくあることです。「揃うまで待つ」か「片方に合わせて壊す」の二択に見えて、期限つきのブランチを1本足すという第三の選択肢があります。重要なのは恒久構成にしないことと、畳む条件(今回は開発環境の 3.13 移行完了)を最初に決めておくことでした。

依存管理ツールの移行は「ファイルを置き換えるだけ」と見積もられがちです。実際に時間を取られたのは、ツールと OS の実行環境、そして移行進度の差との接続部分でした。

## まとめ

- Python 3.9 はアップストリームでは 2025 年 10 月に EOL だが、RHEL 9 系ではライフサイクル全体でサポートされる(Red Hat, 2026)
- `PrivateTmp=` は `/tmp` の隔離で、ホームを隠すのは `ProtectHome=`(systemd, 2026a)。症状が同じでも原因設定は別
- systemd はシェルを介さず `ExecStart` を実行するため pyenv の shims 前提は成立しない(systemd, 2026b)
- アプリケーションで Poetry を使うなら `package-mode = false`(Poetry, 2026a)
- 直接依存を2つ外すと推移的依存 17 個が道連れに消える(追加分込みで 48→38)。ロックファイルの実利はここに出る
- 移行進度がずれるときは、畳む条件を決めたうえで `production` ブランチを一時的に立てる

次は開発環境を 3.13 + Poetry に揃え、`production` を `main` へ統合します。二重管理を前提にした構成は、終わらせるところまでが設計だと考えています。

## 参考文献

本記事は技術テーマのため学術論文は参照せず、公式ドキュメント(一次資料)に基づいています。

### 公式ドキュメント

- Gunicorn. (2026). *Deploying Gunicorn*. 2026年8月閲覧. https://docs.gunicorn.org/en/latest/deploy.html
- Poetry. (2026a). *Basic usage*. 2026年8月閲覧. https://python-poetry.org/docs/basic-usage/
- Poetry. (2026b). *Commands*. 2026年8月閲覧. https://python-poetry.org/docs/cli/
- Poetry. (2026c). *The pyproject.toml file*. 2026年8月閲覧. https://python-poetry.org/docs/pyproject/
- pyenv. (2026). *pyenv: Understanding shims*. GitHub. 2026年8月閲覧. https://github.com/pyenv/pyenv#understanding-shims
- Python Package Index. (2026). *anthropic*. 2026年8月閲覧. https://pypi.org/project/anthropic/
- Python Software Foundation. (2026). *Status of Python versions*. Python Developer's Guide. 2026年8月閲覧. https://devguide.python.org/versions/
- Red Hat. (2026). *Chapter 1. Introduction to Python*（Red Hat Enterprise Linux 9: Installing and using dynamic programming languages）. 2026年8月閲覧. https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/installing_and_using_dynamic_programming_languages/assembly_introduction-to-python_installing-and-using-dynamic-programming-languages
- systemd. (2026a). *systemd.exec(5)*. Linux manual page. 2026年8月閲覧. https://man7.org/linux/man-pages/man5/systemd.exec.5.html
- systemd. (2026b). *systemd.service(5)*. Linux manual page. 2026年8月閲覧. https://man7.org/linux/man-pages/man5/systemd.service.5.html
