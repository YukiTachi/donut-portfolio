#!/usr/local/bin/bash
#
# generate-blog.sh
# ----------------
# Notion「ブログネタ」から 1 件取り出し、Claude Code を非対話モードで起動して
# エビデンスベースのブログ記事(draft: true)を自動生成・push し、結果をメール通知する。
#
# cron での実行例(毎日 19:00):
#   0 19 * * * /home/yukit/donut-portfolio/scripts/generate-blog.sh
#
# 仕様: docs/blog-cron-handoff.md / docs/blog-automation.md を参照。

set -uo pipefail

# ===== 設定 =====================================================================
REPO="/home/yukit/donut-portfolio"
SCRIPT_DIR="${REPO}/scripts"
PROMPT_FILE="${SCRIPT_DIR}/cron-blog-prompt.md"

CLAUDE_BIN="/home/yukit/.local/bin/claude"   # cron は PATH が異なるためフルパス指定
MSMTP_BIN="/usr/local/bin/msmtp"
TIMEOUT_BIN="/usr/bin/timeout"

MAIL_FROM="cron@donut-service.com"
MAIL_TO="yuki.tachi@donut-service.com"
MSMTP_ACCOUNT="blog-cron"

# Notion「ブログネタ」ページの URL(メール文面用。設定済みなら記入する)
NOTION_PAGE_URL="https://app.notion.com/p/371d745d3f8380e49431e784cd244d77"

LOCKFILE="/tmp/blog-cron.lock"
TIMEOUT_SECS=1800            # Claude Code 実行のタイムアウト(30 分)
LOG_DIR="${HOME}/log"
LOG_RETENTION_DAYS=30
MAIL_FOOTER="このメールは FreeBSD EC2 上の blog-cron から自動送信されています。"

# ===== 初期化 ===================================================================
mkdir -p "${LOG_DIR}"
TODAY="$(date +%F)"                       # YYYY-MM-DD
LOG_FILE="${LOG_DIR}/blog-cron-${TODAY}.log"
START_HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

# Claude の生出力を保存する一時ファイル
CLAUDE_OUT="$(mktemp "/tmp/blog-cron-out.XXXXXX")"

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
  find "${LOG_DIR}" -name 'blog-cron-*.log' -type f -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null
}

# ===== メール送信 ===============================================================
# send_mail <subject> <body>
send_mail() {
  local subject="$1"
  local body="$2"
  {
    printf 'From: %s\n' "${MAIL_FROM}"
    printf 'To: %s\n' "${MAIL_TO}"
    printf 'Subject: %s\n' "${subject}"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=UTF-8\n'
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

# Git の現状(失敗メール用)
git_state() {
  echo "  status:"
  git -C "${REPO}" status --short 2>&1 | sed 's/^/    /'
  echo "  HEAD:"
  git -C "${REPO}" log -1 --oneline 2>&1 | sed 's/^/    /'
}

# ===== メール本文ビルダー =======================================================
build_success_body() {
  local warn_note="$1"   # Notion 警告がある場合に渡す注記(無ければ空)
  cat <<EOF
ブログ記事の自動生成が完了しました(下書き / draft: true)。
${warn_note}
■ 記事情報
  タイトル : $(get_field TITLE)
  ファイル : $(get_field FILE)
  文字数   : $(get_field CHARS)
  タグ     : $(get_field TAGS)
  draft    : $(get_field DRAFT)

■ 元ネタ
  $(get_field TOPIC)

■ 参考文献(カテゴリ別件数)
  学術論文       : $(get_field EVIDENCE_PAPER)
  公式ドキュメント : $(get_field EVIDENCE_OFFICIAL)
  政府・公的資料   : $(get_field EVIDENCE_GOV)
  Web記事        : $(get_field EVIDENCE_WEB)

■ レビュー手順
  1. ローカルで確認: cd ${REPO} && git pull && npm run dev
  2. 記事ファイルを開いて内容・出典・トーンを確認
  3. 問題なければ frontmatter の draft: true → false に変更
  4. git commit & push で公開

■ 処理ログ
  開始     : ${START_HUMAN}
  終了     : $(date '+%Y-%m-%d %H:%M:%S')
  所要時間 : $(elapsed_human)
  ログ     : ${LOG_FILE}

■ Git 情報
  ブランチ       : $(get_field BRANCH)
  コミットハッシュ : $(get_field COMMIT)
  メッセージ      : $(get_field COMMIT_MSG)
  push           : $(get_field PUSH)
  Notion 更新     : $(get_field NOTION)
EOF
}

build_failure_body() {
  local phase_label="$1"
  local error_summary="$2"
  cat <<EOF
ブログ記事の自動生成に失敗しました。

■ 失敗フェーズ
  ${phase_label}

■ 元ネタ
  $(get_field TOPIC)

■ エラー概要
  ${error_summary}

■ 処理状況
  Notion: 対象行の復元 = $(get_field NOTION_RESTORED)
  Git:
$(git_state)

■ 処理ログ
  開始     : ${START_HUMAN}
  終了     : $(date '+%Y-%m-%d %H:%M:%S')
  所要時間 : $(elapsed_human)
  ログ     : ${LOG_FILE}

■ エラー詳細(ログ末尾 100 行)
$(log_tail)

■ 次のアクション
  1. 上記ログで失敗箇所を確認
  2. Notion「ブログネタ」の対象行が「未処理」に戻っているか確認
     (戻っていなければ手動で戻す)
  3. Git の作業ツリーに未 push の変更が残っていないか確認
  4. 必要に応じて手動で再実行: bash ${SCRIPT_DIR}/generate-blog.sh
EOF
}

build_skip_body() {
  local link_line="Notion「ブログネタ」ページ"
  if [[ -n "${NOTION_PAGE_URL}" ]]; then
    link_line="${NOTION_PAGE_URL}"
  fi
  cat <<EOF
本日のブログ記事自動生成はスキップしました。

■ 理由
  Notion「ブログネタ」の「未処理」セクションに処理対象のネタがありませんでした。
  $(get_field MESSAGE)

■ ネタの追加方法
  スマホの Notion App で「ブログネタ」ページの「未処理」に箇条書きを 1 行追加してください。
  次回(翌日 19:00)の実行時に自動で処理されます。

■ Notion
  ${link_line}

■ 処理ログ
  開始 : ${START_HUMAN}
  ログ : ${LOG_FILE}
EOF
}

# ===== メイン ===================================================================
main() {
  acquire_lock
  rotate_logs

  log "===== blog-cron 開始 (PID $$) ====="

  # 前提チェック
  if [[ ! -x "${CLAUDE_BIN}" ]]; then
    log "claude が見つかりません: ${CLAUDE_BIN}"
    send_mail "[blog-cron] 記事生成失敗: 環境エラー" \
      "claude 実行ファイルが見つからないか実行権限がありません: ${CLAUDE_BIN}"
    exit 1
  fi
  if [[ ! -f "${PROMPT_FILE}" ]]; then
    log "プロンプトファイルが見つかりません: ${PROMPT_FILE}"
    send_mail "[blog-cron] 記事生成失敗: 環境エラー" \
      "プロンプトファイルが見つかりません: ${PROMPT_FILE}"
    exit 1
  fi

  cd "${REPO}" || {
    log "リポジトリへ移動できません: ${REPO}"
    send_mail "[blog-cron] 記事生成失敗: 環境エラー" \
      "リポジトリディレクトリへ移動できません: ${REPO}"
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
    send_mail "[blog-cron] 記事生成失敗: 実行タイムアウト(${TIMEOUT_SECS}秒)" \
      "$(build_failure_body "実行タイムアウト" "Claude Code が ${TIMEOUT_SECS} 秒以内に完了しませんでした。")"
    exit 1
  fi

  # --- Claude プロセス自体の失敗 ---
  if [[ ${cc_rc} -ne 0 ]]; then
    log "Claude Code が異常終了しました(rc=${cc_rc})。"
    send_mail "[blog-cron] 記事生成失敗: Claude Code 実行エラー" \
      "$(build_failure_body "Claude Code 実行" "Claude Code が非ゼロ終了しました(終了コード ${cc_rc})。")"
    exit 1
  fi

  # --- サマリーブロックの抽出 ---
  extract_result_block
  if [[ -z "${RESULT_BLOCK}" ]]; then
    log "サマリーブロックが出力にありません。"
    send_mail "[blog-cron] 記事生成失敗: 出力パース失敗" \
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
      send_mail "[blog-cron] スキップ: ブログネタなし" "$(build_skip_body)"
      ;;

    SUCCESS)
      local push notion title
      push="$(get_field PUSH)"
      notion="$(get_field NOTION)"
      title="$(get_field TITLE)"

      if [[ "${push}" == "FAILED" ]]; then
        # git push 失敗は失敗扱い
        log "記事生成は完了したが git push に失敗。"
        send_mail "[blog-cron] 記事生成失敗: Git push 失敗" \
          "$(build_failure_body "Git push" "記事はローカルに commit 済みですが、git push に失敗しました。")"
        exit 1
      fi

      if [[ "${notion}" == "FAILED" ]]; then
        # 記事生成は成功だが Notion 更新に失敗 → 警告つき成功メール
        log "成功(ただし Notion 更新に失敗): ${title}"
        send_mail "[blog-cron] 記事生成成功(警告): ${title}" \
          "$(build_success_body "⚠ 注意: Notion「ブログネタ」の完了処理に失敗しました。対象行を手動で「完了」へ移動してください。")"
      else
        log "成功: ${title}"
        send_mail "[blog-cron] 記事生成成功: ${title}" \
          "$(build_success_body "")"
      fi
      ;;

    ERROR)
      local phase phase_label err
      phase="$(get_field ERROR_PHASE)"
      err="$(get_field ERROR)"
      case "${phase}" in
        topic_fetch)   phase_label="ネタ取得" ;;
        paper_search)  phase_label="論文検索" ;;
        generation)    phase_label="記事生成" ;;
        format_check)  phase_label="フォーマット検証" ;;
        git_push)      phase_label="Git push" ;;
        notion_update) phase_label="Notion更新" ;;
        *)             phase_label="不明(${phase})" ;;
      esac
      log "失敗(${phase_label}): ${err}"
      send_mail "[blog-cron] 記事生成失敗: ${err}" \
        "$(build_failure_body "${phase_label}" "${err}")"
      exit 1
      ;;

    *)
      log "RESULT が不正な値です: '${result}'"
      send_mail "[blog-cron] 記事生成失敗: 不明な結果" \
        "$(build_failure_body "Claude Code 実行(結果判定)" "RESULT の値が不正です: '${result}'")"
      exit 1
      ;;
  esac

  log "===== blog-cron 終了 ====="
}

main "$@"
