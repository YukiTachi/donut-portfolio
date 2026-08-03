#!/usr/local/bin/bash
#
# generate-brainsync-blog.sh
# --------------------------
# Notion「BrainSyncブログ」から 1 件取り出し、Claude Code を非対話モードで起動して
# エビデンスベースの記事を生成し、WordPress(donut-service.com)へ
# post_status: draft で投入して結果をメール通知する。
#
# Astro 版(generate-blog.sh)との違い:
#   - Git の commit / push / デプロイを行わない
#   - 記事は WordPress MCP 経由で下書き投入のみ。自動公開は一切しない
#   - 失敗時にオーファン下書きが残りうるため、投稿 ID を通知に含める
#
# cron での実行例(毎週日曜 21:00 JST = UTC 12:00):
#   0 12 * * 0 /home/yukit/donut-portfolio/scripts/generate-brainsync-blog.sh
#
# 前提:
#   - FreeBSD EC2 上の Claude Code に WordPress MCP(donut-wp)が登録済みであること
#   - その登録が WORKDIR から見えること(--scope local の場合はディレクトリ依存)
#     確認: cd "${WORKDIR}" && claude mcp list

set -uo pipefail

# ===== 設定 =====================================================================
# Claude Code の MCP 登録スコープに合わせた作業ディレクトリ。
# --scope local で登録した場合、ここが登録時のディレクトリと一致していないと
# MCP サーバーが見えないので注意(--scope user なら任意で可)。
WORKDIR="/home/yukit/donut-portfolio"
SCRIPT_DIR="${WORKDIR}/scripts"
PROMPT_FILE="${SCRIPT_DIR}/cron-brainsync-prompt.md"

CLAUDE_BIN="/home/yukit/.local/bin/claude"   # cron は PATH が異なるためフルパス指定
MSMTP_BIN="/usr/local/bin/msmtp"
TIMEOUT_BIN="/usr/bin/timeout"

MAIL_FROM="cron@donut-service.com"
MAIL_TO="yuki.tachi@donut-service.com"
MSMTP_ACCOUNT="blog-cron"

# Notion「BrainSyncブログ」ページ
NOTION_PAGE_URL="https://app.notion.com/p/3aad745d3f8381f9b95ff2a2f656ed4c"

# WordPress 管理画面(編集リンク生成用)
WP_ADMIN_BASE="https://donut-service.com/wp-admin"

# Astro 版と衝突しないよう、ロック・ログはすべて別名にする
LOCKFILE="/tmp/brainsync-blog-cron.lock"
TIMEOUT_SECS=1800            # Claude Code 実行のタイムアウト(30 分)
LOG_DIR="${HOME}/log"
LOG_PREFIX="brainsync-cron"
LOG_RETENTION_DAYS=30
MAIL_FOOTER="このメールは FreeBSD EC2 上の brainsync-cron から自動送信されています。"

# ===== 初期化 ===================================================================
mkdir -p "${LOG_DIR}"
TODAY="$(date +%F)"                       # YYYY-MM-DD
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}-${TODAY}.log"
START_HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

# Claude の生出力を保存する一時ファイル
CLAUDE_OUT="$(mktemp "/tmp/${LOG_PREFIX}-out.XXXXXX")"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}"
}

# 終了時クリーンアップ(ロック解除・一時ファイル削除)
cleanup() {
  rm -f "${CLAUDE_OUT}"
  rm -f "${LOCKFILE}"
}

# ===== 二重起動防止(ロックファイル) ===========================================
# `set -o noclobber` により、ロックファイルの作成は「存在しなければ作る/あれば失敗」が原子的になる。
acquire_lock() {
  if ( set -o noclobber; echo "$$" > "${LOCKFILE}" ) 2>/dev/null; then
    trap cleanup EXIT
    return 0
  fi
  # 既にロックがある → プロセスが生きているか確認(スタールロック検出)
  local old_pid
  old_pid="$(cat "${LOCKFILE}" 2>/dev/null)"
  if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
    log "別プロセス(PID ${old_pid})が実行中のため起動を中止しました。"
    exit 0
  fi
  # スタールロック → 奪取
  log "スタールロックを検出(PID ${old_pid:-不明})。ロックを再取得します。"
  if ( set -o noclobber; echo "$$" > "${LOCKFILE}" ) 2>/dev/null; then
    trap cleanup EXIT
    return 0
  fi
  rm -f "${LOCKFILE}"
  if ( set -o noclobber; echo "$$" > "${LOCKFILE}" ) 2>/dev/null; then
    trap cleanup EXIT
    return 0
  fi
  log "ロックの取得に失敗しました。起動を中止します。"
  exit 1
}

# ===== ログローテーション =======================================================
rotate_logs() {
  find "${LOG_DIR}" -name "${LOG_PREFIX}-*.log" -type f -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null
}

# ===== メール送信 ===============================================================
# 日本語件名は生 UTF-8 のままだと受信側で文字化けするため、
# RFC 2047 encoded-word (UTF-8 / Base64) に変換する。
# base64 は 76 桁ごとに改行を入れるので tr -d '\n' で除去しないとヘッダが壊れる。
encode_subject() {
  printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 | tr -d '\n')"
}

# send_mail <subject> <body>
send_mail() {
  local subject="$1"
  local body="$2"
  {
    printf 'From: %s\n' "${MAIL_FROM}"
    printf 'To: %s\n' "${MAIL_TO}"
    printf 'Subject: %s\n' "$(encode_subject "${subject}")"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf 'Content-Transfer-Encoding: 8bit\n'
    printf '\n'
    printf '%s\n' "${body}"
    printf '\n%s\n' "${MAIL_FOOTER}"
  } | "${MSMTP_BIN}" -a "${MSMTP_ACCOUNT}" "${MAIL_TO}"
  local mail_rc=${PIPESTATUS[1]}   # パイプ最後段(msmtp)の終了コードを明示的に取得

  if [[ ${mail_rc} -eq 0 ]]; then
    log "メール送信成功: ${subject}"
  else
    log "メール送信失敗(rc=${mail_rc}): ${subject}"
  fi
}

# ===== Claude 出力サマリーの抽出 ================================================
# サマリーブロック(===BLOG_CRON_RESULT_BEGIN=== 〜 ===BLOG_CRON_RESULT_END===)だけを取り出す
RESULT_BLOCK=""
extract_result_block() {
  RESULT_BLOCK="$(awk '
    /===BLOG_CRON_RESULT_BEGIN===/ { capture=1; next }
    /===BLOG_CRON_RESULT_END===/   { capture=0 }
    capture { print }
  ' "${CLAUDE_OUT}")"
}

# get_field <KEY> : サマリーブロックから KEY=VALUE の VALUE を返す(無ければ空)
get_field() {
  local key="$1"
  printf '%s\n' "${RESULT_BLOCK}" | grep -m1 "^${key}=" | sed "s/^${key}=//"
}

# 編集画面 URL(投稿 ID から生成)
edit_url() {
  local post_id="$1"
  if [[ -n "${post_id}" ]]; then
    printf '%s/post.php?post=%s&action=edit' "${WP_ADMIN_BASE}" "${post_id}"
  else
    printf '(投稿 ID 不明)'
  fi
}

# 処理時間(人間可読)
elapsed_human() {
  local end_epoch diff
  end_epoch="$(date +%s)"
  diff=$(( end_epoch - START_EPOCH ))
  printf '%d分%d秒' "$(( diff / 60 ))" "$(( diff % 60 ))"
}

# ログ末尾 N 行(失敗メール用)
log_tail() {
  tail -n 100 "${CLAUDE_OUT}" 2>/dev/null
}

# 失敗時に残った可能性のある下書きの情報(Astro 版の git_state 相当)
wp_state() {
  local orphan
  orphan="$(get_field ORPHAN_POST_ID)"
  if [[ -n "${orphan}" ]]; then
    echo "  WordPress に下書きが残っている可能性があります。"
    echo "    投稿 ID : ${orphan}"
    echo "    編集画面 : $(edit_url "${orphan}")"
    echo "    → 不要であればゴミ箱へ移動してください(自動削除はしません)。"
  else
    echo "  WordPress への投稿は行われていません(または投稿 ID を取得できませんでした)。"
  fi
}

# ===== メール本文ビルダー =======================================================
build_success_body() {
  local warn_note="$1"   # Notion 警告がある場合に渡す注記(無ければ空)
  local post_id
  post_id="$(get_field POST_ID)"
  cat <<EOF
BrainSync ブログ記事の自動生成が完了しました(WordPress 下書き)。
${warn_note}
■ 記事情報
  タイトル   : $(get_field TITLE)
  投稿 ID    : ${post_id}
  ステータス : $(get_field POST_STATUS)
  文字数     : $(get_field CHARS)
  カテゴリー : $(get_field CATEGORIES)
  タグ       : $(get_field TAGS)
  編集画面   : $(edit_url "${post_id}")

■ 元ネタ
  $(get_field TOPIC)

■ 参考文献(カテゴリ別件数)
  学術論文         : $(get_field EVIDENCE_PAPER)
  公式ドキュメント : $(get_field EVIDENCE_OFFICIAL)
  政府・公的資料   : $(get_field EVIDENCE_GOV)
  Web記事          : $(get_field EVIDENCE_WEB)

■ 未確定箇所(公開前に埋めるもの)
  [要確認]         : $(get_field PLACEHOLDER_TODO) 件
  [実測データ挿入] : $(get_field PLACEHOLDER_DATA) 件

■ レビュー手順
  1. 編集画面を開く: $(edit_url "${post_id}")
  2. 出典を裏取りする。書誌情報(著者・巻号・年)だけでなく、
     **その研究の結論の向き**まで確認すること
     (肯定的知見を否定側として引用する誤りが実際に発生している)
  3. [要確認] / [実測データ挿入] のプレースホルダをすべて解消
  4. カテゴリー・タグ・アイキャッチ画像を確認
  5. 問題なければ管理画面から公開

  ※ このスクリプトは記事を公開しません。公開は必ず人間が判断します。

■ 処理ログ
  開始     : ${START_HUMAN}
  終了     : $(date '+%Y-%m-%d %H:%M:%S')
  所要時間 : $(elapsed_human)
  ログ     : ${LOG_FILE}

■ Notion
  更新     : $(get_field NOTION)
  ページ   : ${NOTION_PAGE_URL}
EOF
}

build_failure_body() {
  local phase_label="$1"
  local error_summary="$2"
  cat <<EOF
BrainSync ブログ記事の自動生成に失敗しました。

■ 失敗フェーズ
  ${phase_label}

■ 元ネタ
  $(get_field TOPIC)

■ エラー概要
  ${error_summary}

■ 処理状況
  Notion: 対象行の復元 = $(get_field NOTION_RESTORED)
  WordPress:
$(wp_state)

■ 処理ログ
  開始     : ${START_HUMAN}
  終了     : $(date '+%Y-%m-%d %H:%M:%S')
  所要時間 : $(elapsed_human)
  ログ     : ${LOG_FILE}

■ エラー詳細(ログ末尾 100 行)
$(log_tail)

■ 次のアクション
  1. 上記ログで失敗箇所を確認
  2. Notion「BrainSyncブログ」の対象行が「未処理」に戻っているか確認
     (戻っていなければ手動で戻す)
  3. WordPress にオーファン下書きが残っていないか確認
     一覧: ${WP_ADMIN_BASE}/edit.php?post_status=draft&post_type=post
  4. 必要に応じて手動で再実行: bash ${SCRIPT_DIR}/generate-brainsync-blog.sh
EOF
}

build_auth_failure_body() {
  cat <<EOF
BrainSync ブログ記事の自動生成に失敗しました(原因: Claude Code の認証切れ)。

■ 原因
  Claude Code の OAuth トークンが失効しているため、記事生成を開始できませんでした。
  (出力に "401 Invalid authentication credentials" を検出)
  ※ Notion・WordPress には一切変更を加えていません(着手前に停止)。

■ 復旧手順
  1. このサーバーに SSH ログイン
  2. claude を対話起動して再認証: claude → /login(ブラウザ認証を完了)
  3. 疎通確認: ${CLAUDE_BIN} --print "Reply with exactly: AUTH_OK"
     → "AUTH_OK" が返れば復旧。次回 cron から自動で再開します。
  4. すぐ流したい場合は手動再実行: bash ${SCRIPT_DIR}/generate-brainsync-blog.sh

■ 処理ログ
  開始 : ${START_HUMAN}
  終了 : $(date '+%Y-%m-%d %H:%M:%S')
  ログ : ${LOG_FILE}

■ エラー詳細(ログ末尾 100 行)
$(log_tail)
EOF
}

build_wp_failure_body() {
  cat <<EOF
BrainSync ブログ記事の自動生成に失敗しました(原因: WordPress MCP に接続できません)。

■ 原因
  WordPress MCP サーバー(donut-wp)への接続または認証に失敗しました。
  $(get_field ERROR)

■ 確認すべき点
  1. Bearer トークンが有効か
     AI Engine → 設定 → MCP → Bearer Token
  2. MCP エンドポイントが応答するか
     curl -i https://donut-service.com/wp-json/mcp/v1/http
  3. OAuth ディスカバリが 200 を返すか(nginx の /.well-known/ 設定)
     curl -i https://donut-service.com/.well-known/oauth-protected-resource/wp-json/mcp/v1/http
  4. Claude Code から MCP が見えるか
     cd ${WORKDIR} && ${CLAUDE_BIN} mcp list
     → 見えない場合は --scope local で別ディレクトリに登録されている可能性

■ 処理状況
  Notion: 対象行の復元 = $(get_field NOTION_RESTORED)

■ 処理ログ
  開始 : ${START_HUMAN}
  終了 : $(date '+%Y-%m-%d %H:%M:%S')
  ログ : ${LOG_FILE}

■ エラー詳細(ログ末尾 100 行)
$(log_tail)
EOF
}

build_skip_body() {
  cat <<EOF
本日の BrainSync ブログ記事自動生成はスキップしました。

■ 理由
  Notion「BrainSyncブログ」の「未処理」セクションに処理対象のネタがありませんでした。
  $(get_field MESSAGE)

■ ネタの追加方法
  スマホの Notion App で「BrainSyncブログ」ページの「未処理」に箇条書きを 1 行追加してください。
  次回の実行時に自動で処理されます。

■ Notion
  ${NOTION_PAGE_URL}

■ 処理ログ
  開始 : ${START_HUMAN}
  ログ : ${LOG_FILE}
EOF
}

# ===== メイン ===================================================================
main() {
  acquire_lock
  rotate_logs

  log "===== brainsync-cron 開始 (PID $$) ====="

  # 前提チェック
  if [[ ! -x "${CLAUDE_BIN}" ]]; then
    log "claude が見つかりません: ${CLAUDE_BIN}"
    send_mail "[brainsync-cron] 記事生成失敗: 環境エラー" \
      "claude 実行ファイルが見つからないか実行権限がありません: ${CLAUDE_BIN}"
    exit 1
  fi
  if [[ ! -f "${PROMPT_FILE}" ]]; then
    log "プロンプトファイルが見つかりません: ${PROMPT_FILE}"
    send_mail "[brainsync-cron] 記事生成失敗: 環境エラー" \
      "プロンプトファイルが見つかりません: ${PROMPT_FILE}"
    exit 1
  fi

  cd "${WORKDIR}" || {
    log "作業ディレクトリへ移動できません: ${WORKDIR}"
    send_mail "[brainsync-cron] 記事生成失敗: 環境エラー" \
      "作業ディレクトリへ移動できません: ${WORKDIR}"
    exit 1
  }

  # Claude Code を非対話モードで起動(30 分タイムアウト)
  log "Claude Code を起動します(timeout ${TIMEOUT_SECS}s)。"
  local prompt_text
  prompt_text="$(cat "${PROMPT_FILE}")"

  "${TIMEOUT_BIN}" -k 30s "${TIMEOUT_SECS}s" \
    "${CLAUDE_BIN}" --print \
    --dangerously-skip-permissions \
    "${prompt_text}" > "${CLAUDE_OUT}" 2>&1
  local cc_rc=$?

  # 生出力を当日ログへ追記
  {
    echo "----- Claude Code 出力 (rc=${cc_rc}) -----"
    cat "${CLAUDE_OUT}"
    echo "----- 出力ここまで -----"
  } >> "${LOG_FILE}"

  # --- タイムアウト判定 ---
  if [[ ${cc_rc} -eq 124 || ${cc_rc} -eq 137 ]]; then
    log "Claude Code がタイムアウトしました(rc=${cc_rc})。"
    extract_result_block   # 途中まで出ていれば ORPHAN_POST_ID を拾えることがある
    send_mail "[brainsync-cron] 記事生成失敗: 実行タイムアウト(${TIMEOUT_SECS}秒)" \
      "$(build_failure_body "実行タイムアウト" "Claude Code が ${TIMEOUT_SECS} 秒以内に完了しませんでした。")"
    exit 1
  fi

  # --- 認証切れ(401)判定 ---
  # Claude Code 自体の OAuth 失効。WordPress MCP の 401 とは復旧手段が異なるため、
  # MCP 側のエラー文言(mcp / donut-wp)を含む場合はここでは拾わない。
  if [[ ${cc_rc} -ne 0 ]] \
     && grep -qiE '401|Invalid authentication credentials|Failed to authenticate' "${CLAUDE_OUT}" \
     && ! grep -qiE 'donut-wp|wp-json|mcp server' "${CLAUDE_OUT}"; then
    log "Claude Code の認証が切れています(401, rc=${cc_rc})。"
    send_mail "[brainsync-cron] 記事生成失敗: 認証切れ(/login で復旧してください)" \
      "$(build_auth_failure_body)"
    exit 1
  fi

  # --- Claude プロセス自体の失敗 ---
  if [[ ${cc_rc} -ne 0 ]]; then
    log "Claude Code が異常終了しました(rc=${cc_rc})。"
    extract_result_block
    send_mail "[brainsync-cron] 記事生成失敗: Claude Code 実行エラー" \
      "$(build_failure_body "Claude Code 実行" "Claude Code が非ゼロ終了しました(終了コード ${cc_rc})。")"
    exit 1
  fi

  # --- サマリーブロックの抽出 ---
  extract_result_block
  if [[ -z "${RESULT_BLOCK}" ]]; then
    log "サマリーブロックが出力にありません。"
    send_mail "[brainsync-cron] 記事生成失敗: 出力パース失敗" \
      "$(build_failure_body "Claude Code 実行(出力パース)" "結果サマリーブロックが出力に見つかりませんでした。")"
    exit 1
  fi

  local result
  result="$(get_field RESULT)"
  log "RESULT=${result}"

  # --- 結果による分岐 ---
  case "${result}" in
    SKIP)
      log "スキップ(未処理ネタなし)。"
      send_mail "[brainsync-cron] スキップ: ブログネタなし" "$(build_skip_body)"
      ;;

    SUCCESS)
      local post_id post_status notion title
      post_id="$(get_field POST_ID)"
      post_status="$(get_field POST_STATUS)"
      notion="$(get_field NOTION)"
      title="$(get_field TITLE)"

      # 投稿 ID が取れていなければ成功扱いにしない
      if [[ -z "${post_id}" ]]; then
        log "RESULT=SUCCESS だが POST_ID が空。"
        send_mail "[brainsync-cron] 記事生成失敗: 投稿 ID 不明" \
          "$(build_failure_body "WordPress 投稿(結果検証)" "RESULT=SUCCESS ですが POST_ID が取得できませんでした。")"
        exit 1
      fi

      # 誤って公開されていないかを最終ガードとして検査する
      if [[ "${post_status}" != "draft" ]]; then
        log "投稿ステータスが draft ではありません: ${post_status}"
        send_mail "[brainsync-cron] 要確認: 記事が draft 以外で作成されました(ID ${post_id})" \
          "$(build_failure_body "WordPress 投稿(ステータス検証)" \
             "post_status が '${post_status}' になっています。意図しない公開の可能性があるため、至急 $(edit_url "${post_id}") を確認してください。")"
        exit 1
      fi

      if [[ "${notion}" == "FAILED" ]]; then
        # 記事投入は成功だが Notion 更新に失敗 → 警告つき成功メール
        # (次回実行で同じネタが再生成されるおそれがあるため、手動対応を促す)
        log "成功(ただし Notion 更新に失敗): ${title}"
        send_mail "[brainsync-cron] 記事生成成功(警告): ${title}" \
          "$(build_success_body "⚠ 注意: Notion「BrainSyncブログ」の完了処理に失敗しました。対象行を手動で「処理中」へ移動してください。放置すると次回実行で同じネタが再生成されます。")"
      else
        log "成功: ${title} (投稿 ID ${post_id})"
        send_mail "[brainsync-cron] 記事生成成功: ${title}" \
          "$(build_success_body "")"
      fi
      ;;

    ERROR)
      local phase phase_label err
      phase="$(get_field ERROR_PHASE)"
      err="$(get_field ERROR)"

      # WordPress MCP への接続失敗は復旧手順が異なるため専用メールで切り分ける
      if [[ "${phase}" == "wp_connect" ]]; then
        log "WordPress MCP に接続できません: ${err}"
        send_mail "[brainsync-cron] 記事生成失敗: WordPress MCP 接続エラー" \
          "$(build_wp_failure_body)"
        exit 1
      fi

      case "${phase}" in
        topic_fetch)   phase_label="ネタ取得" ;;
        research)      phase_label="調査・出典収集" ;;
        generation)    phase_label="記事生成" ;;
        format_check)  phase_label="フォーマット検証" ;;
        wp_create)     phase_label="WordPress 投稿" ;;
        notion_update) phase_label="Notion更新" ;;
        *)             phase_label="不明(${phase})" ;;
      esac
      log "失敗(${phase_label}): ${err}"
      send_mail "[brainsync-cron] 記事生成失敗: ${err}" \
        "$(build_failure_body "${phase_label}" "${err}")"
      exit 1
      ;;

    *)
      log "RESULT が不正な値です: '${result}'"
      send_mail "[brainsync-cron] 記事生成失敗: 不明な結果" \
        "$(build_failure_body "Claude Code 実行(結果判定)" "RESULT の値が不正です: '${result}'")"
      exit 1
      ;;
  esac

  log "===== brainsync-cron 終了 ====="
}

main "$@"
