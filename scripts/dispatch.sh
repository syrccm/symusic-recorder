#!/usr/bin/env bash
# 예약 발사기 — R2 의 reservations.json 을 읽어 때가 된 예약의 녹음(record.yml)을 띄운다.
# dispatcher.yml 이 10분마다 실행한다.
#
# 하는 일(순서대로)
#   1. reservations.json 읽기 (없으면 빈 목록. 읽기 오류면 아무것도 쓰지 않고 실패)
#   2. 채널 /streams 탭을 읽어 예정·진행 중 라이브 목록(upcoming.json) 갱신
#   3. 녹음(record.yml)이 이미 돌고 있는지 확인
#   4. video 예약 → weekly 예약 순으로 판정. 한 번 실행에 녹음은 최대 1건만 띄운다.
#   5. 바뀐 필드만 최신 reservations.json 에 덮어써서 다시 올린다.
#
# 환경 변수
#   R2_ACCOUNT_ID, R2_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  R2 접근
#   GH_TOKEN, GITHUB_REPOSITORY   record.yml 실행·실행 목록 조회
#   LIVE_URL                      채널 주소 유도(…/live → …/streams)와 weekly 의 대체 주소
#   DRY_RUN=1                     모의 실행: 녹음을 띄우지 않고 R2 에 쓰지 않는다(읽기는 한다)
#   검증용(로컬에서 시나리오를 돌릴 때):
#     NOW=<epoch>                 현재 시각 주입
#     RES_IN=<파일>               R2 대신 이 reservations.json 을 읽는다
#     UPCOMING_IN=<파일>          유튜브 조회 대신 이 upcoming.json 을 쓴다
#     RES_OUT=<파일>              결과 reservations.json 을 이 파일로 쓴다(R2 에는 쓰지 않음)
#     BUSY=0|1                    녹음 실행 중 여부를 지정(실행 목록 조회 생략)
#     KST_TZ                      시간대 이름을 지원하지 않는 셸용(기본 Asia/Seoul)

set -euo pipefail

KST_TZ="${KST_TZ:-Asia/Seoul}"
DRY_RUN="${DRY_RUN:-0}"
LIVE_URL="${LIVE_URL:-}"
now="${NOW:-$(date +%s)}"

MATCH_WINDOW_SECONDS=2700     # weekly ↔ 예정 라이브 매칭 허용 오차(±45분)
VIDEO_EXPIRE_MARGIN=3600      # video 예약 정리: scheduled_at + max_minutes + 이 여유가 지나면 삭제
MIN_WAIT_MINUTES=5

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '[%s] %s\n' "$(TZ="$KST_TZ" date -d "@$now" +%H:%M)" "$*"; }
iso() { TZ="$KST_TZ" date -d "@$1" +%Y-%m-%dT%H:%M:%S+09:00; }
is_int() { [[ "$1" =~ ^[0-9]{1,4}$ ]]; }

ENDPOINT="https://${R2_ACCOUNT_ID:-}.r2.cloudflarestorage.com"

# r2_get KEY FILE → 0: 받음, 1: 객체 없음, 2: 그 밖의 오류
r2_get() {
  local err
  if err="$(aws s3 cp "s3://${R2_BUCKET}/$1" "$2" --endpoint-url "$ENDPOINT" --only-show-errors 2>&1)"; then
    return 0
  fi
  if grep -qE '404|NoSuchKey|does not exist' <<<"$err"; then return 1; fi
  log "오류: R2 읽기 실패($1): ${err:0:200}"
  return 2
}

r2_put() {
  aws s3 cp "$1" "s3://${R2_BUCKET}/$2" --endpoint-url "$ENDPOINT" \
    --content-type "application/json; charset=utf-8" --only-show-errors
}

# ── 1. 예약 읽기 ─────────────────────────────────────────────────
SEEN="$WORK/seen.json"
load_reservations() { # $1 = 대상 파일
  if [ -n "${RES_IN:-}" ]; then
    cp "$RES_IN" "$1"
  else
    local rc=0
    r2_get reservations.json "$1" || rc=$?
    if [ "$rc" = 1 ]; then echo '{"items":[]}' >"$1"; elif [ "$rc" != 0 ]; then return 1; fi
  fi
  jq -e '(.items | type) == "array"' "$1" >/dev/null 2>&1 || {
    log "오류: reservations.json 형식이 올바르지 않습니다(items 배열이 없음). 아무것도 바꾸지 않습니다."
    return 1
  }
}
load_reservations "$SEEN"
COUNT="$(jq '.items | length' "$SEEN")"
log "예약 ${COUNT}건 읽음"

# ── 2. 예정 라이브 목록(upcoming.json) ───────────────────────────
UPCOMING="$WORK/upcoming.json"

refresh_upcoming() {
  local prev="$WORK/upcoming.prev.json" flat="$WORK/flat.json" lines="$WORK/upcoming.ndjson"
  local base full id title status ts rc=0

  r2_get upcoming.json "$prev" || rc=$?
  if [ "$rc" != 0 ] || ! jq -e '(.items | type) == "array"' "$prev" >/dev/null 2>&1; then
    echo '{"items":[]}' >"$prev"
  fi
  cp "$prev" "$UPCOMING" # 조회에 실패하면 이전 목록을 그대로 쓴다

  if [[ "$LIVE_URL" =~ ^(https://www\.youtube\.com/(@[^/?#]+|channel/[^/?#]+|c/[^/?#]+)) ]]; then
    base="${BASH_REMATCH[1]}"
  else
    log "경고: LIVE_URL 에서 채널 주소를 알 수 없어 예정 라이브 목록을 갱신하지 않습니다."
    return 0
  fi

  if ! yt-dlp --no-warnings --flat-playlist --playlist-end 30 -J "${base}/streams" >"$flat" 2>"$WORK/ytdlp.err"; then
    log "경고: 채널 스트림 목록 조회 실패 — 이전 목록을 유지합니다: $(tail -n 1 "$WORK/ytdlp.err" | cut -c1-200)"
    return 0
  fi

  # 매 시 첫 실행(0~9분)에는 예정 시각을 전부 다시 조회하고, 그 밖에는 이미 아는 값은 재사용한다(유튜브 조회 줄이기).
  full=0
  if [ $(((now / 60) % 60)) -lt 10 ]; then full=1; fi

  : >"$lines"
  while IFS=$'\t' read -r id status; do
    [[ "$id" =~ ^[A-Za-z0-9_-]{11}$ ]] || continue
    title="$(jq -r --arg id "$id" '[.entries[]? | select(.id == $id) | .title // ""][0] // ""' "$flat")"
    ts=""
    if [ "$full" = 0 ]; then
      ts="$(jq -r --arg id "$id" '[.items[] | select(.video_id == $id) | .scheduled_ts // empty][0] // empty' "$prev")"
    fi
    if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
      ts="$(yt-dlp --no-warnings --ignore-no-formats-error --skip-download \
        --print '%(release_timestamp)s' -- "https://www.youtube.com/watch?v=${id}" 2>/dev/null | tail -n 1 || true)"
    fi
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      jq -cn --arg id "$id" --arg title "$title" --arg status "$status" --argjson ts "$ts" --arg at "$(iso "$ts")" \
        '{video_id: $id, title: $title, scheduled_at: $at, scheduled_ts: $ts, status: $status}' >>"$lines"
    else
      jq -cn --arg id "$id" --arg title "$title" --arg status "$status" \
        '{video_id: $id, title: $title, scheduled_at: null, scheduled_ts: null, status: $status}' >>"$lines"
    fi
  done < <(jq -r '.entries[]?
      | select(.live_status == "is_upcoming" or .live_status == "is_live")
      | [.id, (if .live_status == "is_live" then "live" else "upcoming" end)] | @tsv' "$flat" | head -n 15)

  jq -s --arg at "$(iso "$now")" \
    '{updated_at: $at, items: (. | sort_by(.scheduled_ts // 9999999999))}' "$lines" >"$UPCOMING"
  log "예정·진행 중 라이브 $(jq '.items | length' "$UPCOMING")건"

  if [ "$DRY_RUN" = 1 ]; then
    log "[모의] upcoming.json 은 올리지 않습니다."
  else
    r2_put "$UPCOMING" upcoming.json || log "경고: upcoming.json 업로드 실패"
  fi
}

if [ -n "${UPCOMING_IN:-}" ]; then
  cp "$UPCOMING_IN" "$UPCOMING"
else
  refresh_upcoming
fi

# ── 3. 녹음이 이미 돌고 있는가 ───────────────────────────────────
if [ -z "${BUSY:-}" ]; then
  ACTIVE="$(gh run list --repo "$GITHUB_REPOSITORY" --workflow record.yml --limit 10 --json status \
    --jq '[.[] | select(.status != "completed")] | length')"
  if [ "$ACTIVE" -gt 0 ]; then BUSY=1; else BUSY=0; fi
fi
log "녹음 실행 중: $([ "$BUSY" = 1 ] && echo 예 || echo 아니오)"

# ── 변경 기록 ────────────────────────────────────────────────────
# 예약 파일 전체를 덮어쓰지 않고, 바꿀 필드({id: {...}})와 지울 id 만 모았다가 마지막에 최신본에 적용한다.
PATCH="$WORK/patch.json"
echo '{"set":{},"remove":[]}' >"$PATCH"
patch_set() { # ID JSON
  jq --arg id "$1" --argjson v "$2" '.set[$id] = ((.set[$id] // {}) + $v)' "$PATCH" >"$PATCH.tmp" && mv "$PATCH.tmp" "$PATCH"
}
patch_remove() { # ID
  jq --arg id "$1" '.remove += [$id]' "$PATCH" >"$PATCH.tmp" && mv "$PATCH.tmp" "$PATCH"
}

field() { # INDEX JQ식 → 값(없으면 빈 문자열)
  jq -r --argjson i "$1" ".items[\$i] | ($2) // empty" "$SEEN"
}

# ── 녹음 띄우기 ──────────────────────────────────────────────────
SID=""
dispatch() { # 예약ID 제목 VIDEO_ID(빈 값 가능) WAIT분 MAX분
  SID="r-$(TZ="$KST_TZ" date -d "@$now" +%Y%m%d-%H%M)-$(printf '%04x' $(((RANDOM << 1 ^ RANDOM) & 0xffff)))"
  local args=(-f "session_id=$SID" -f "title=$2" -f "wait_minutes=$4" -f "max_minutes=$5" -f "reservation_id=$1")
  if [ -n "$3" ]; then args+=(-f "video_id=$3"); fi
  if [ "$DRY_RUN" = 1 ]; then
    log "[모의] 녹음 실행: 예약=$1 session=$SID video=${3:-(채널 /live)} wait=$4분 max=$5분"
  else
    gh workflow run record.yml --repo "$GITHUB_REPOSITORY" --ref "${GITHUB_REF_NAME:-main}" "${args[@]}"
    log "녹음 실행: 예약=$1 session=$SID video=${3:-(채널 /live)} wait=$4분 max=$5분"
  fi
  BUSY=1 # 한 번 실행에 1건만
}

# 분 단위 값을 읽는다. 없거나 형식이 틀리면 기본값.
minutes() { # INDEX 필드 기본값
  local v
  v="$(field "$1" ".$2")"
  if is_int "$v"; then echo "$v"; else echo "$3"; fi
}

# ── 4-1. video 예약 ──────────────────────────────────────────────
for ((i = 0; i < COUNT; i++)); do
  [ "$(field "$i" '.kind')" = "video" ] || continue
  id="$(field "$i" '.id')"
  if ! [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then log "경고: ${i}번째 예약의 id 형식이 올바르지 않아 건너뜁니다."; continue; fi
  vid="$(field "$i" '.video_id')"
  at="$(field "$i" '.scheduled_at')"
  if ! [[ "$vid" =~ ^[A-Za-z0-9_-]{11}$ ]]; then log "경고: video 예약 $id: video_id 형식 오류 — 건너뜀"; continue; fi
  if ! sched="$(date -d "$at" +%s 2>/dev/null)"; then log "경고: video 예약 $id: scheduled_at 을 읽을 수 없음 — 건너뜀"; continue; fi
  lead="$(minutes "$i" lead_minutes 30)"
  max="$(minutes "$i" max_minutes 150)"
  wait="$(minutes "$i" wait_minutes $((lead + 90)))"
  dispatched="$(field "$i" '.dispatched_at')"
  wait_until=$((sched + (wait - lead) * 60)) # 이 시각까지 라이브 시작을 기다린다(늦게 띄워도 같은 시각)

  if [ "$now" -gt $((sched + max * 60 + VIDEO_EXPIRE_MARGIN)) ]; then
    log "video 예약 $id: 지난 예약 정리(예정 $(iso "$sched"))"
    patch_remove "$id"
  elif [ -n "$dispatched" ]; then
    log "video 예약 $id: 이미 실행함($dispatched)"
  elif [ "$now" -lt $((sched - lead * 60)) ]; then
    log "video 예약 $id: 아직 이름(예정 $(iso "$sched"), ${lead}분 전부터 실행)"
  elif [ "$BUSY" = 1 ]; then
    log "video 예약 $id: 보류 — 다른 녹음이 실행 중. 다음 실행에서 다시 확인"
  else
    w=$(((wait_until - now + 59) / 60))
    if [ "$w" -lt "$MIN_WAIT_MINUTES" ]; then w="$MIN_WAIT_MINUTES"; fi
    dispatch "$id" "$(field "$i" '.title')" "$vid" "$w" "$max"
    patch_set "$id" "$(jq -cn --arg at "$(iso "$now")" --arg sid "$SID" '{dispatched_at: $at, session_id: $sid}')"
  fi
done

# ── 4-2. weekly 예약 ─────────────────────────────────────────────
for ((i = 0; i < COUNT; i++)); do
  [ "$(field "$i" '.kind')" = "weekly" ] || continue
  id="$(field "$i" '.id')"
  if ! [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then log "경고: ${i}번째 예약의 id 형식이 올바르지 않아 건너뜁니다."; continue; fi
  weekday="$(field "$i" '.weekday')"
  time="$(field "$i" '.time')"
  tz="$(field "$i" '.tz')"
  [ -n "$tz" ] || tz="$KST_TZ"
  if ! [[ "$weekday" =~ ^[0-6]$ && "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && "$tz" =~ ^[A-Za-z0-9_/+-]{1,40}$ ]]; then
    log "경고: weekly 예약 $id: weekday/time/tz 형식 오류 — 건너뜀"
    continue
  fi
  lead="$(minutes "$i" lead_minutes 10)"
  wait="$(minutes "$i" wait_minutes 60)"
  max="$(minutes "$i" max_minutes 150)"

  # 어제·오늘·내일 중 요일이 맞고 "대상 시각 − lead ≤ 지금 < 대상 시각 + wait" 인 회차를 찾는다.
  # (자정을 넘는 경우: 00:10 예배는 전날 23:40 에 띄워야 하고, 23:50 예배는 다음 날 00:20 에도 아직 유효하다)
  target=""
  target_date=""
  for off in -1 0 1; do
    d="$(TZ="$tz" date -d "@$((now + off * 86400))" +%Y-%m-%d)"
    [ "$(TZ="$tz" date -d "$d 12:00" +%w)" = "$weekday" ] || continue
    t="$(TZ="$tz" date -d "$d $time" +%s)"
    if [ "$now" -ge $((t - lead * 60)) ] && [ "$now" -lt $((t + wait * 60)) ]; then
      target="$t"
      target_date="$d"
      break
    fi
  done
  if [ -z "$target" ]; then
    log "weekly 예약 $id: 지금은 실행 구간이 아님(요일 $weekday $time)"
    continue
  fi
  if [ "$(field "$i" '.last_dispatched_date')" = "$target_date" ]; then
    log "weekly 예약 $id: $target_date 회차는 이미 처리함"
    continue
  fi

  # 예정 라이브 중 대상 시각과 ±45분 안에 있는 것을 가까운 순으로. 가장 가까운 것을 고른다.
  mapfile -t cands < <(jq -r --argjson t "$target" --argjson win "$MATCH_WINDOW_SECONDS" '
      [.items[]? | select(.scheduled_ts != null)
        | {video_id, title, scheduled_at, diff: ((.scheduled_ts - $t) | fabs)} | select(.diff <= $win)]
      | sort_by(.diff)[] | [.video_id, (.diff / 60 | floor | tostring), (.scheduled_at // ""), (.title // "")] | @tsv' "$UPCOMING")
  vid=""
  if [ "${#cands[@]}" -gt 0 ]; then
    for c in "${cands[@]}"; do
      IFS=$'\t' read -r c_vid c_diff c_at c_title <<<"$c"
      log "weekly 예약 $id: 후보 $c_vid (예정 $c_at, 차이 ${c_diff}분) $c_title"
    done
    IFS=$'\t' read -r vid _ <<<"${cands[0]}"
    log "weekly 예약 $id: 가장 가까운 $vid 선택(후보 ${#cands[@]}건)"
  else
    log "weekly 예약 $id: ±45분 안에 예정 라이브가 없어 채널 /live 로 대체"
  fi

  # 같은 영상을 video 예약이 맡고 있으면 중복으로 띄우지 않는다.
  if [ -n "$vid" ]; then
    owner="$(jq -r --arg v "$vid" '[.items[] | select(.kind == "video" and .video_id == $v)][0] | .id // empty' "$SEEN")"
    if [ -n "$owner" ]; then
      owner_done="$(jq -r --arg id "$owner" '[.items[] | select(.id == $id)][0].dispatched_at // empty' "$SEEN")"
      owner_now="$(jq -r --arg id "$owner" '.set[$id].dispatched_at // empty' "$PATCH")"
      if [ -n "$owner_done" ] || [ -n "$owner_now" ]; then
        log "weekly 예약 $id: 같은 영상을 video 예약 $owner 이 이미 실행 — 이 회차는 처리한 것으로 기록"
        patch_set "$id" "$(jq -cn --arg d "$target_date" '{last_dispatched_date: $d}')"
      else
        log "weekly 예약 $id: 같은 영상의 video 예약 $owner 에 맡김(아직 실행 전)"
      fi
      continue
    fi
  fi

  if [ "$BUSY" = 1 ]; then
    log "weekly 예약 $id: 보류 — 다른 녹음이 실행 중. 구간 안에서 다음 실행 때 다시 확인"
    continue
  fi
  if [ -z "$vid" ] && [ -z "$LIVE_URL" ]; then
    log "경고: weekly 예약 $id: 예정 라이브도 LIVE_URL 도 없어 실행할 수 없음"
    continue
  fi
  w=$(((target + wait * 60 - now + 59) / 60))
  if [ "$w" -lt "$MIN_WAIT_MINUTES" ]; then w="$MIN_WAIT_MINUTES"; fi
  dispatch "$id" "$(field "$i" '.title')" "$vid" "$w" "$max"
  patch_set "$id" "$(jq -cn --arg d "$target_date" --arg at "$(iso "$now")" --arg sid "$SID" --arg v "$vid" \
    '{last_dispatched_date: $d, last_dispatched_at: $at, last_session_id: $sid,
      last_video_id: (if $v == "" then null else $v end)}')"
done

# ── 5. 변경 반영 ─────────────────────────────────────────────────
if [ "$(jq '(.set | length) + (.remove | length)' "$PATCH")" = 0 ]; then
  log "예약 변경 없음"
  exit 0
fi

# 쓰기 직전에 최신본을 다시 받아, 이번에 바꾼 필드만 id 기준으로 덮어쓴다.
# 지울 항목은 읽었을 때와 내용이 같을 때만 지운다(그 사이 앱이 고쳤으면 남긴다).
FRESH="$WORK/fresh.json"
load_reservations "$FRESH"
jq --slurpfile p "$PATCH" --slurpfile s "$SEEN" '
  $p[0] as $P
  | ($s[0].items | map(select(.id != null) | {key: (.id | tostring), value: .}) | from_entries) as $seen
  | .items |= (
      map(. as $it | select((($P.remove | index($it.id)) == null) or ($seen[$it.id | tostring] != $it)))
      | map(. + ($P.set[.id | tostring] // {}))
    )' "$FRESH" >"$WORK/out.json"

if [ -n "${RES_OUT:-}" ]; then
  cp "$WORK/out.json" "$RES_OUT"
  log "결과를 $RES_OUT 에 기록"
elif [ "$DRY_RUN" = 1 ]; then
  log "[모의] reservations.json 은 올리지 않습니다. 바뀔 내용: $(jq -c . "$PATCH")"
else
  r2_put "$WORK/out.json" reservations.json
  log "reservations.json 갱신"
fi
