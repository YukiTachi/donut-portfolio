#!/usr/local/bin/bash
#
# nginx-healthcheck.sh
# --------------------
# donut-software.com の死活を確認し、落ちていたら nginx を自動復旧して
# メール通知する。2026-08-03 の OOM kill による 4 日間の沈黙(FreeBSD rc は
# 死んだサービスを自動再起動しない)の再発防止策。
#
# cron での実行例(5 分間隔):
#   */5 * * * * /home/yukit/donut-portfolio/scripts/nginx-healthcheck.sh
#
# 動作:
#   1. 公開 URL に HTTPS でアクセス(10 秒タイムアウト)
#   2. 失敗したら 5 秒待って再試行(瞬断の誤検知防止)
#   3. それでも失敗なら nginx を start / restart して再確認
#   4. 結果をメール通知(復旧成功 / 復旧失敗)。ダウン継続中の再通知は
#      60 分に 1 回に抑制。復旧を検知したら回復通知を送る
#
# 前提:
#   - yukit が sudo -n で service を実行できること
#   - msmtp のアカウント blog-cron が設定済みであること
#
# 手動テスト:
#   ./nginx-healthcheck.sh --selftest   # メール送信のみ確認

set -uo pipefail

# ===== 設定 =====================================================================
CHECK_URL="https://donut-software.com/"
CURL_TIMEOUT=10
RETRY_WAIT=5

MSMTP_BIN="/usr/local/bin/msmtp"
MAIL_FROM="cron@donut-service.com"
MAIL_TO="yuki.tachi@donut-service.com"
MSMTP_ACCOUNT="blog-cron"
MAIL_FOOTER="このメールは FreeBSD EC2 上の nginx-healthcheck から自動送信されています。"

STATE_FILE="/tmp/nginx-healthcheck.state"   # ダウン検知時刻と最終通知時刻を保持
RENOTIFY_SECS=3600                          # ダウン継続中の再通知間隔(60 分)
LOCKFILE="/tmp/nginx-healthcheck.lock"

LOG_DIR="${HOME}/log"
LOG_PREFIX="nginx-healthcheck"
LOG_RETENTION_DAYS=30

# ===== 初期化 ===================================================================
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}-$(date +%F).log"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "${LOG_FILE}"
}

# send_mail <subject> <body>
send_mail() {
  local subject="$1"
  local body="$2"
  {
    printf 'From: %s\n' "${MAIL_FROM}"
    printf 'To: %s\n' "${MAIL_TO}"
    printf 'Subject: %s\n' "${subject}"
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf '\n%s\n' "${body}"
    printf '\n%s\n' "${MAIL_FOOTER}"
  } | "${MSMTP_BIN}" -a "${MSMTP_ACCOUNT}" "${MAIL_TO}"
  local mail_rc=${PIPESTATUS[1]}
  if [[ ${mail_rc} -eq 0 ]]; then
    log "メール送信成功: ${subject}"
  else
    log "メール送信失敗(rc=${mail_rc}): ${subject}"
  fi
}

check_http() {
  curl -fsS -o /dev/null --max-time "${CURL_TIMEOUT}" "${CHECK_URL}"
}

# ===== セルフテスト =============================================================
if [[ "${1:-}" == "--selftest" ]]; then
  send_mail "[nginx-healthcheck] テスト通知" \
    "メール送信経路の確認です。このメールが届いていれば通知は機能しています。"
  exit 0
fi

# ===== 多重起動防止 =============================================================
if ! mkdir "${LOCKFILE}" 2>/dev/null; then
  # 前回の実行が残っている(最長でも curl タイムアウト+再起動程度で終わるはず)
  exit 0
fi
trap 'rmdir "${LOCKFILE}"' EXIT

# ===== 死活確認 =================================================================
if check_http; then
  # 正常。直前までダウンしていた(=状態ファイルがある)なら回復を通知
  if [[ -f "${STATE_FILE}" ]]; then
    down_since="$(head -1 "${STATE_FILE}")"
    rm -f "${STATE_FILE}"
    log "回復を検知(ダウン検知: ${down_since})"
    send_mail "[nginx-healthcheck] 回復: donut-software.com" \
      "サイトの応答が回復しました。
ダウン検知: ${down_since}
回復確認: $(date '+%Y-%m-%d %H:%M:%S')"
  fi
  exit 0
fi

# 瞬断の可能性があるので少し待って再試行
sleep "${RETRY_WAIT}"
if check_http; then
  log "1 回目の確認は失敗したが再試行で成功(瞬断とみなす)"
  exit 0
fi

# ===== ダウン確定 → 復旧試行 ====================================================
now_human="$(date '+%Y-%m-%d %H:%M:%S')"
log "ダウンを検知: ${CHECK_URL} が応答しない"

if service nginx status >/dev/null 2>&1; then
  # プロセスは生きているが応答しない → restart
  action="restart"
  sudo -n service nginx restart >> "${LOG_FILE}" 2>&1
else
  # プロセスが死んでいる(OOM kill 等)→ start
  action="start"
  sudo -n service nginx start >> "${LOG_FILE}" 2>&1
fi
recover_rc=$?
log "service nginx ${action} を実行(rc=${recover_rc})"

sleep 3

if check_http; then
  log "復旧成功"
  rm -f "${STATE_FILE}"
  send_mail "[nginx-healthcheck] 自動復旧: donut-software.com" \
    "サイトのダウンを検知し、自動復旧しました。
検知時刻: ${now_human}
実行内容: service nginx ${action}
現在の状態: HTTPS 応答 OK

原因調査には /var/log/messages(OOM kill の有無)と
/var/log/nginx/error.log を確認してください。"
  exit 0
fi

# ===== 復旧失敗 → 通知(60 分に 1 回に抑制)====================================
log "復旧失敗: ${action} 後も応答なし"
now_epoch="$(date +%s)"
last_notify=0
if [[ -f "${STATE_FILE}" ]]; then
  last_notify="$(tail -1 "${STATE_FILE}")"
else
  printf '%s\n0\n' "${now_human}" > "${STATE_FILE}"
fi

if (( now_epoch - last_notify >= RENOTIFY_SECS )); then
  down_since="$(head -1 "${STATE_FILE}")"
  printf '%s\n%s\n' "${down_since}" "${now_epoch}" > "${STATE_FILE}"
  send_mail "[nginx-healthcheck] 復旧失敗: donut-software.com がダウンしています" \
    "サイトのダウンを検知しましたが、自動復旧に失敗しました。手動対応が必要です。
ダウン検知: ${down_since}
復旧試行: service nginx ${action}(rc=${recover_rc})

サーバーに ssh して以下を確認してください:
  sudo nginx -t
  tail -50 /var/log/nginx/error.log
  tail -20 /var/log/messages"
fi
exit 1
