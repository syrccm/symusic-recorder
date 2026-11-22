#!/usr/bin/env bash
# 유튜브 라이브를 mp3(64kbps 모노)로 녹음한다.
#
#   yt-dlp ──(FIFO)──▶ ffmpeg ──▶ out.mp3
#
# 단계
#   waiting    WAIT_MINUTES > 0 일 때. yt-dlp --wait-for-video 로 예정 라이브가 시작되기를 기다린다.
#   recording  첫 데이터가 out.mp3 에 쓰인 뒤. MAX_MINUTES 는 이 시점부터 센다.
#
# 종료 조건(어느 것이든 yt-dlp 프로세스 그룹에 SIGTERM → 파이프 닫힘 → ffmpeg 정상 마감):
#   stop_signal   리포 변수 STOP_SIGNAL 값이 SESSION_ID 와 같아짐 (10초마다 확인, 대기 중에도 동작)
#   max_minutes   녹음 시작 후 MAX_MINUTES 경과
#   stream_ended  방송 종료(yt-dlp 가 스스로 끝남)
#   wait_timeout  WAIT_MINUTES(+60초) 안에 라이브가 시작되지 않음 → exit 1
#   no_data       WAIT_MINUTES=0 인데 60초 안에 데이터가 없음(봇 차단·방송 미시작 등) → exit 1
#
# 환경 변수
#   SESSION_ID        (필수) 세션 id
#   VIDEO_ID          (선택) 있으면 https://www.youtube.com/watch?v={id} 를 녹음
#   LIVE_URL          VIDEO_ID 가 없을 때 필수
#   WAIT_MINUTES      (기본 0) 라이브 시작을 기다릴 최대 시간(분)
#   MAX_MINUTES       (기본 120) 녹음 시작 후 최대 녹음 시간(분)
#   YTDLP_FORMAT      (기본 bestaudio/best)
#   YTDLP_EXTRA_ARGS  (기본 비움) 셸 인용 규칙으로 분해해 yt-dlp 에 그대로 전달
#   YT_COOKIES_FILE   (선택) 쿠키 파일 경로
#   GH_TOKEN, GITHUB_REPOSITORY  STOP_SIGNAL 조회용 (없으면 조회 생략)
#   OUT               (기본 out.mp3)
#   진행 상태 기록용(전부 있을 때만 R2 의 state/current.json 을 쓴다. 없으면 생략 — 로컬 실행):
#     R2_ACCOUNT_ID, R2_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#     TITLE, RESERVATION_ID, RUN_ID, STARTED_AT (상태 파일에 그대로 적는 값)

set -euo pipefail

LIVE_URL="${LIVE_URL:-}"
VIDEO_ID="${VIDEO_ID:-}"
SESSION_ID="${SESSION_ID:-}"
WAIT_MINUTES="${WAIT_MINUTES:-0}"
MAX_MINUTES="${MAX_MINUTES:-120}"
YTDLP_FORMAT="${YTDLP_FORMAT:-bestaudio/best}"
YTDLP_EXTRA_ARGS="${YTDLP_EXTRA_ARGS:-}"
OUT="${OUT:-out.mp3}"

POLL_SECONDS=10
DATA_GRACE_SECONDS=60   # 대기 시한 뒤(또는 즉시 녹음 시작 뒤) 첫 데이터까지 허용하는 여유
WAIT_RETRY_SECONDS=30   # yt-dlp --wait-for-video 재시도 간격
STATE_KEY="state/current.json"

log() { printf '[%s] %s\n' "$(TZ=Asia/Seoul date +%H:%M:%S)" "$*"; }

[ -n "$SESSION_ID" ] || { log "오류: SESSION_ID 가 비어 있습니다."; exit 2; }
if [ -n "$VIDEO_ID" ]; then
  [[ "$VIDEO_ID" =~ ^[A-Za-z0-9_-]{11}$ ]] || { log "오류: VIDEO_ID 형식이 올바르지 않습니다."; exit 2; }
  URL="https://www.youtube.com/watch?v=${VIDEO_ID}"
else
  [ -n "$LIVE_URL" ] || { log "오류: VIDEO_ID 와 LIVE_URL 이 모두 비어 있습니다."; exit 2; }
  URL="$LIVE_URL"
fi
[[ "$WAIT_MINUTES" =~ ^[0-9]+$ ]] || { log "오류: WAIT_MINUTES 값이 올바르지 않습니다: $WAIT_MINUTES"; exit 2; }
if ! [[ "$MAX_MINUTES" =~ ^[0-9]+$ ]] || [ "$MAX_MINUTES" -lt 1 ]; then
  log "오류: MAX_MINUTES 값이 올바르지 않습니다: $MAX_MINUTES"
  exit 2
fi

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
    [ "$n" -gt 0 ] || return 1
    sleep 1 || true
    n=$((n - 1))
  done
  return 0
}

out_bytes() { stat -c %s "$OUT" 2>/dev/null || echo 0; }

# ── 진행 상태(state/current.json) ────────────────────────────────
# 앱이 "대기 중/녹음 중"을 구분해 보여 주기 위한 파일. 기록 실패는 녹음을 멈추지 않는다.
state_enabled() {
  [ -n "${R2_ACCOUNT_ID:-}" ] && [ -n "${R2_BUCKET:-}" ] &&
    [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] &&
    command -v aws >/dev/null 2>&1
}

write_state() {
  state_enabled || return 0
  jq -n \
    --arg phase "$1" \
    --arg session_id "$SESSION_ID" \
    --arg title "${TITLE:-}" \
    --arg video_id "$VIDEO_ID" \
    --arg reservation_id "${RESERVATION_ID:-}" \
    --arg run_id "${RUN_ID:-}" \
    --arg started_at "${STARTED_AT:-}" \
    --arg updated_at "$(TZ=Asia/Seoul date +%Y-%m-%dT%H:%M:%S+09:00)" \
    '{phase: $phase, session_id: $session_id, title: $title,
      video_id: (if $video_id == "" then null else $video_id end),
      reservation_id: (if $reservation_id == "" then null else $reservation_id end),
      run_id: $run_id, started_at: $started_at, updated_at: $updated_at}' >"$TMP/state.json" &&
    aws s3 cp "$TMP/state.json" "s3://${R2_BUCKET}/${STATE_KEY}" \
      --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
      --content-type "application/json; charset=utf-8" --only-show-errors ||
    log "경고: 상태 파일(${STATE_KEY}) 기록에 실패했습니다. 녹음은 계속합니다."
}

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
if [ "$WAIT_MINUTES" -gt 0 ]; then
  # 인자는 "재시도 간격(초)"이다. 총 대기 시간은 아래 감시 루프가 제한한다.
  EXTRA+=(--wait-for-video "$WAIT_RETRY_SECONDS")
fi

log "시작: session=$SESSION_ID format=$YTDLP_FORMAT wait=${WAIT_MINUTES}분 max=${MAX_MINUTES}분"
if [ "$WAIT_MINUTES" -gt 0 ]; then write_state waiting; else write_state recording; fi

ffmpeg -hide_banner -loglevel warning -nostdin -y \
  -i "$FIFO" -vn -ac 1 -ar 44100 -c:a libmp3lame -b:a 64k \
  -flush_packets 1 "$OUT" &
FFMPEG_PID=$!

# setsid: yt-dlp 와 그 자식(내부 ffmpeg 다운로더)을 별도 프로세스 그룹으로 묶어
# 그룹 전체에 신호를 보낸다. 자식이 남아 파이프를 붙잡는 일을 막기 위함.
# R2 자격 증명은 yt-dlp 쪽 프로세스에 넘기지 않는다.
env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u GH_TOKEN \
  setsid yt-dlp --no-progress -f "$YTDLP_FORMAT" "${EXTRA[@]}" -o - -- "$URL" >"$FIFO" &
YTDLP_PID=$!

CANCELLED=0
trap 'CANCELLED=1' INT TERM

START="$(date +%s)"
DATA_DEADLINE=$((START + WAIT_MINUTES * 60 + DATA_GRACE_SECONDS))
DEADLINE=0 # 녹음 시작(첫 데이터) 후에 정해진다
NEXT_POLL=$((START + POLL_SECONDS))
NEXT_PROGRESS=$((START + 300))
GOT_DATA=0
REC_START=0
REASON=""

# ── 감시 루프 ────────────────────────────────────────────────────
while alive "$YTDLP_PID"; do
  sleep 1 || true
  NOW="$(date +%s)"

  if [ "$CANCELLED" = 1 ]; then REASON="cancelled"; break; fi

  if [ "$GOT_DATA" = 0 ]; then
    if [ "$(out_bytes)" -gt 0 ]; then
      GOT_DATA=1
      REC_START="$NOW"
      DEADLINE=$((REC_START + MAX_MINUTES * 60))
      log "녹음 시작(첫 데이터 수신). 대기 $(( (NOW - START) / 60 ))분."
      if [ "$WAIT_MINUTES" -gt 0 ]; then write_state recording; fi
    elif [ "$NOW" -ge "$DATA_DEADLINE" ]; then
      if [ "$WAIT_MINUTES" -gt 0 ]; then REASON="wait_timeout"; else REASON="no_data"; fi
      break
    fi
  elif [ "$NOW" -ge "$DEADLINE" ]; then
    REASON="max_minutes"
    break
  fi

  if [ "$NOW" -ge "$NEXT_POLL" ]; then
    NEXT_POLL=$((NOW + POLL_SECONDS))
    if stop_requested; then REASON="stop_signal"; break; fi
  fi

  if [ "$NOW" -ge "$NEXT_PROGRESS" ]; then
    NEXT_PROGRESS=$((NOW + 300))
    if [ "$GOT_DATA" = 1 ]; then
      log "녹음 중: $(( (NOW - REC_START) / 60 ))분 경과, $(out_bytes) bytes"
      write_state recording # updated_at 갱신
    else
      log "라이브 시작 대기 중: $(( (NOW - START) / 60 ))분 경과"
      write_state waiting
    fi
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
YT_RC=0
wait "$YTDLP_PID" 2>/dev/null || YT_RC=$?

# 파이프가 닫혔으니 ffmpeg 가 스스로 mp3 를 마감한다.
if ! wait_exit "$FFMPEG_PID" "$FF_GRACE"; then
  log "ffmpeg 가 끝나지 않아 SIGTERM 을 보냅니다."
  kill -TERM "$FFMPEG_PID" 2>/dev/null || true
  wait_exit "$FFMPEG_PID" 15 || kill -KILL "$FFMPEG_PID" 2>/dev/null || true
fi
FF_RC=0
wait "$FFMPEG_PID" 2>/dev/null || FF_RC=$?
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

if [ "$REASON" = "cancelled" ]; then
  exit 130
fi
if [ "$BYTES" -eq 0 ]; then
  case "$REASON" in
    stop_signal)
      log "라이브 시작 전에 정지 요청을 받아 녹음 없이 끝냅니다."
      exit 0
      ;;
    wait_timeout)
      log "오류: ${WAIT_MINUTES}분을 기다렸지만 라이브가 시작되지 않았습니다."
      ;;
    *)
      log "오류: 녹음된 데이터가 없습니다(0바이트). 봇 차단, 방송 미시작, 잘못된 주소일 수 있습니다."
      log "      위 yt-dlp 로그를 확인하고 README 의 '봇 차단 시 대응 순서'를 따르세요."
      ;;
  esac
  exit 1
fi
exit 0
