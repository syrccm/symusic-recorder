#!/usr/bin/env bash
# 유튜브 라이브를 mp3(64kbps 모노)로 녹음한다.
#
#   yt-dlp ──(FIFO)──▶ ffmpeg ──▶ out.mp3
#
# 종료 조건(어느 것이든 yt-dlp 프로세스 그룹에 SIGTERM → 파이프 닫힘 → ffmpeg 정상 마감):
#   - 리포 변수 STOP_SIGNAL 값이 현재 SESSION_ID 와 같아짐 (10초마다 확인)
#   - MAX_MINUTES 경과
#   - 방송 종료(yt-dlp 가 스스로 끝남)
#   - 시작 60초 후에도 out.mp3 가 0바이트(봇 차단 등) → exit 1
#
# 환경 변수
#   LIVE_URL          (필수) 라이브 주소
#   SESSION_ID        (필수) 앱이 만든 세션 id
#   MAX_MINUTES       (기본 120)
#   YTDLP_FORMAT      (기본 bestaudio/best)
#   YTDLP_EXTRA_ARGS  (기본 비움) 셸 인용 규칙으로 분해해 yt-dlp 에 그대로 전달
#   YT_COOKIES_FILE   (선택) 쿠키 파일 경로
#   GH_TOKEN, GITHUB_REPOSITORY  STOP_SIGNAL 조회용 (없으면 조회 생략)
#   OUT               (기본 out.mp3)

set -uo pipefail

LIVE_URL="${LIVE_URL:-}"
SESSION_ID="${SESSION_ID:-}"
MAX_MINUTES="${MAX_MINUTES:-120}"
YTDLP_FORMAT="${YTDLP_FORMAT:-bestaudio/best}"
YTDLP_EXTRA_ARGS="${YTDLP_EXTRA_ARGS:-}"
OUT="${OUT:-out.mp3}"

POLL_SECONDS=10
STARTUP_CHECK_SECONDS=60

log() { printf '[%s] %s\n' "$(TZ=Asia/Seoul date +%H:%M:%S)" "$*"; }

[ -n "$LIVE_URL" ] || { log "오류: LIVE_URL 이 비어 있습니다."; exit 2; }
[ -n "$SESSION_ID" ] || { log "오류: SESSION_ID 가 비어 있습니다."; exit 2; }
[[ "$MAX_MINUTES" =~ ^[0-9]+$ ]] && [ "$MAX_MINUTES" -gt 0 ] || {
  log "오류: MAX_MINUTES 값이 올바르지 않습니다: $MAX_MINUTES"; exit 2; }

TMP="$(mktemp -d)"
FIFO="$TMP/audio.fifo"
mkfifo "$FIFO"
rm -f "$OUT"

# 좀비가 아닌 살아 있는 프로세스인지
alive() {
  local s
  s="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  [[ -n "$s" && "$s" != Z* ]]
}

# 최대 $2 초 동안 프로세스 종료를 기다린다. 끝났으면 0.
wait_exit() {
  local n="$2"
  while alive "$1"; do
    [ "$n" -le 0 ] && return 1
    sleep 1
    n=$((n - 1))
  done
  return 0
}

out_bytes() { stat -c %s "$OUT" 2>/dev/null || echo 0; }

# ── STOP_SIGNAL 조회 ─────────────────────────────────────────────
LAST_API_CODE=""
stop_requested() {
  [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || return 1
  local code val
  code="$(curl -sS -o "$TMP/var.json" -w '%{http_code}' --max-time 8 \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/actions/variables/STOP_SIGNAL" \
    2>/dev/null)" || code="000"
  if [ "$code" != "$LAST_API_CODE" ]; then
    case "$code" in
      200) ;;
      404) log "STOP_SIGNAL 변수가 아직 없습니다(정상). 계속 확인합니다." ;;
      *)   log "경고: STOP_SIGNAL 조회 실패(HTTP $code). 원격 정지가 동작하지 않을 수 있습니다 — README 의 GH_VARS_TOKEN 참고." ;;
    esac
    LAST_API_CODE="$code"
  fi
  [ "$code" = "200" ] || return 1
  val="$(jq -r '.value // ""' "$TMP/var.json" 2>/dev/null)" || return 1
  [ "$val" = "$SESSION_ID" ]
}

# ── 파이프라인 시작 ──────────────────────────────────────────────
EXTRA=()
if [ -n "$YTDLP_EXTRA_ARGS" ]; then
  mapfile -t EXTRA < <(printf '%s' "$YTDLP_EXTRA_ARGS" | xargs -r -n1 printf '%s\n')
fi
if [ -n "${YT_COOKIES_FILE:-}" ] && [ -s "$YT_COOKIES_FILE" ]; then
  EXTRA+=(--cookies "$YT_COOKIES_FILE")
  log "쿠키 파일 사용"
fi

log "녹음 시작: session=$SESSION_ID format=$YTDLP_FORMAT max=${MAX_MINUTES}분"

ffmpeg -hide_banner -loglevel warning -nostdin -y \
  -i "$FIFO" -vn -ac 1 -ar 44100 -c:a libmp3lame -b:a 64k \
  -flush_packets 1 "$OUT" &
FFMPEG_PID=$!

# setsid: yt-dlp 와 그 자식(내부 ffmpeg 다운로더)을 별도 프로세스 그룹으로 묶어
# 그룹 전체에 신호를 보낸다. 자식이 남아 파이프를 붙잡는 일을 막기 위함.
setsid yt-dlp --no-progress -f "$YTDLP_FORMAT" "${EXTRA[@]}" -o - -- "$LIVE_URL" >"$FIFO" &
YTDLP_PID=$!

CANCELLED=0
trap 'CANCELLED=1' INT TERM

START="$(date +%s)"
DEADLINE=$((START + MAX_MINUTES * 60))
NEXT_POLL=$((START + POLL_SECONDS))
NEXT_PROGRESS=$((START + 60))
STARTUP_CHECKED=0
REASON=""

# ── 감시 루프 ────────────────────────────────────────────────────
while alive "$YTDLP_PID"; do
  sleep 1
  NOW="$(date +%s)"

  if [ "$CANCELLED" = 1 ]; then REASON="cancelled"; break; fi

  if [ "$STARTUP_CHECKED" = 0 ] && [ $((NOW - START)) -ge "$STARTUP_CHECK_SECONDS" ]; then
    STARTUP_CHECKED=1
    if [ "$(out_bytes)" -eq 0 ]; then REASON="no_data"; break; fi
  fi

  if [ "$NOW" -ge "$DEADLINE" ]; then REASON="max_minutes"; break; fi

  if [ "$NOW" -ge "$NEXT_POLL" ]; then
    NEXT_POLL=$((NOW + POLL_SECONDS))
    if stop_requested; then REASON="stop_signal"; break; fi
  fi

  if [ "$NOW" -ge "$NEXT_PROGRESS" ]; then
    NEXT_PROGRESS=$((NOW + 300))
    log "녹음 중: $(( (NOW - START) / 60 ))분 경과, $(out_bytes) bytes"
  fi
done
[ -n "$REASON" ] || REASON="stream_ended"
log "종료 사유: $REASON"

# ── 마감 ─────────────────────────────────────────────────────────
# 취소 시에는 러너가 곧 강제 종료하므로 대기 시간을 짧게 잡는다.
if [ "$REASON" = "cancelled" ]; then YT_GRACE=3; FF_GRACE=4; else YT_GRACE=15; FF_GRACE=60; fi

kill -TERM -- "-$YTDLP_PID" 2>/dev/null || kill -TERM "$YTDLP_PID" 2>/dev/null || true
if ! wait_exit "$YTDLP_PID" "$YT_GRACE"; then
  log "yt-dlp 가 끝나지 않아 강제 종료합니다."
fi
kill -KILL -- "-$YTDLP_PID" 2>/dev/null || true
wait "$YTDLP_PID" 2>/dev/null
YT_RC=$?

# 파이프가 닫혔으니 ffmpeg 가 스스로 mp3 를 마감한다.
if ! wait_exit "$FFMPEG_PID" "$FF_GRACE"; then
  log "ffmpeg 가 끝나지 않아 SIGTERM 을 보냅니다."
  kill -TERM "$FFMPEG_PID" 2>/dev/null || true
  wait_exit "$FFMPEG_PID" 15 || kill -KILL "$FFMPEG_PID" 2>/dev/null || true
fi
wait "$FFMPEG_PID" 2>/dev/null
FF_RC=$?
rm -rf "$TMP"

# ── 결과 ─────────────────────────────────────────────────────────
BYTES="$(out_bytes)"
DURATION=0
if [ "$BYTES" -gt 0 ]; then
  RAW="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" 2>/dev/null || true)"
  DURATION="$(awk -v d="${RAW:-0}" 'BEGIN { printf "%d", d + 0.5 }')"
fi

log "결과: duration_sec=$DURATION bytes=$BYTES stop_reason=$REASON (yt-dlp rc=$YT_RC, ffmpeg rc=$FF_RC)"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "duration_sec=$DURATION"
    echo "bytes=$BYTES"
    echo "stop_reason=$REASON"
  } >>"$GITHUB_OUTPUT"
fi

if [ "$BYTES" -eq 0 ]; then
  log "오류: 녹음된 데이터가 없습니다(0바이트). 봇 차단, 방송 미시작, 잘못된 주소일 수 있습니다."
  log "      위 yt-dlp 로그를 확인하고 README 의 '봇 차단 시 대응 순서'를 따르세요."
  exit 1
fi
if [ "$REASON" = "cancelled" ]; then
  exit 130
fi
exit 0
