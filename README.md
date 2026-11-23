# symusic-recorder

유튜브 라이브(예배 실황)를 GitHub Actions 러너에서 mp3(64kbps 모노)로 녹음해 Cloudflare R2 비공개 버킷에 올린다.
즉시 녹음의 시작과 종료는 symusic 앱(Vercel API)이 `workflow_dispatch` 와 리포 변수로 제어하고,
예약 녹음은 이 리포의 발사기(dispatcher)가 R2 의 예약 파일을 읽어 제때 띄운다.

> 이 리포는 공개다. 워크플로 입력값·리포 변수·실행 이름·로그는 누구나 볼 수 있으므로 제목 등에 개인정보를 넣지 않는다.
> 시크릿은 로그에서 자동으로 가려진다.

## 구조

```
.github/workflows/record.yml      녹음(필요하면 라이브 시작까지 대기) → R2 업로드
.github/workflows/dispatcher.yml  예약 발사기: 10분마다 예약 확인 · 예정 라이브 목록 갱신
scripts/record.sh                 yt-dlp → ffmpeg 녹음 + 대기 + 정지 감시 + 진행 상태 기록
scripts/dispatch.sh               예약 판정 · 녹음 실행 · 예약 파일 갱신
worker/                           발사기를 10분마다 깨우는 Cloudflare Worker
```

## 녹음 (record.yml)

입력:

| 입력 | 기본 | 설명 |
| --- | --- | --- |
| `session_id` | (필수) | 세션 id. 영문·숫자·`-`·`_` 1~64자 |
| `title` | (아무것도 입력하지 않음) | 제목 |
| `video_id` | (아무것도 입력하지 않음) | 유튜브 영상 id. 있으면 `https://www.youtube.com/watch?v={id}` 를 녹음 |
| `live_url` | (아무것도 입력하지 않음) | `video_id` 가 없을 때 쓰는 주소. 비우면 리포 변수 `LIVE_URL` |
| `wait_minutes` | `0` | 라이브 시작을 기다릴 최대 시간(분). `0` 이면 기다리지 않고 바로 녹음 |
| `max_minutes` | (아무것도 입력하지 않음) | **녹음 시작 후** 최대 녹음 시간(분). 비우면 변수 `MAX_MINUTES`, 없으면 120 |
| `reservation_id` | (아무것도 입력하지 않음) | 예약 id(기록용) |

`wait_minutes` 는 180 까지, `wait_minutes + max_minutes` 는 330 까지로 제한된다(작업 제한 360분에서 업로드 시간을 뺀 값).

흐름:

1. `scripts/record.sh` 가 `yt-dlp → (FIFO) → ffmpeg` 로 `out.mp3` 를 쓴다.
   `wait_minutes > 0` 이면 `yt-dlp --wait-for-video` 로 예정 라이브가 시작되기를 기다린다(**waiting** 단계).
2. 첫 데이터가 들어오면 **recording** 단계가 되고 `max_minutes` 를 세기 시작한다.
3. 아래 중 하나가 일어나면 yt-dlp 를 끝내고 ffmpeg 가 파일을 정상 마감한다.

   | 종료 사유(`stop_reason`) | 뜻 |
   | --- | --- |
   | `stream_ended` | 방송 종료 |
   | `stop_signal` | 리포 변수 `STOP_SIGNAL` 이 이 실행의 `session_id` 와 같아짐. 10초마다 확인하며 **대기 중에도** 동작 |
   | `max_minutes` | 녹음 시작 후 `max_minutes` 경과 |
   | `wait_timeout` | `wait_minutes` 안에 라이브가 시작되지 않음 → 실패 |
   | `no_data` | `wait_minutes=0` 인데 60초 안에 데이터가 없음(봇 차단·방송 미시작 등) → 실패 |
   | `cancelled` | 실행이 취소됨 |

4. R2 에 업로드한다. 녹음 step 이 실패·취소돼도 부분 mp3 가 있으면 올린다. 아티팩트는 쓰지 않는다.
5. 진행 상태 파일(`state/current.json`)을 지운다.

동시 실행은 1건이다(`concurrency: record`). 녹음 중(대기 포함)에 새로 dispatch 하면 대기열에 들어가며, 대기 중인 실행이 이미 있으면 그 실행은 새 것으로 교체된다.

참고: 채널의 `/live` 주소는 방송 중이 아니면 **가장 가까운 예정 라이브**로 연결된다. 그래서 `wait_minutes=0` 으로 방송 전에 실행하면 `no_data` 로 실패한다.

## 예약 (dispatcher.yml)

발사기는 약 10분마다 돌며 `scripts/dispatch.sh` 를 실행한다.

발사기는 Cloudflare Worker 가 10분마다 깨운다. GitHub schedule 은 보조.
Worker(`worker/`, 이름 `symusic-recorder-wake`)는 크론 `*/10 * * * *` 로 `dispatcher.yml` 의 `workflow_dispatch` 를 호출한다.
둘이 겹쳐도 `concurrency: dispatcher` 가 동시에 도는 것을 막는다.

```bash
cd worker
npx wrangler deploy            # 배포
npx wrangler secret put GH_PAT # 이 리포의 Actions 쓰기 권한이 있는 토큰(값은 붙여넣기)
npx wrangler tail              # 실시간 로그. 204 가 아니면 상태 코드와 본문 앞 200자가 오류로 남는다
```

1. R2 의 `reservations.json` 을 읽는다.
2. 채널 `/streams` 탭에서 예정·진행 중 라이브를 읽어 `upcoming.json` 을 갱신한다. 채널 주소는 변수 `LIVE_URL`(`…/live`)에서 유도한다.
3. 녹음이 이미 실행 중(대기 포함)인지 확인한다.
4. video 예약 → weekly 예약 순으로 판정해 때가 된 것의 `record.yml` 을 띄운다. **한 번 실행에 최대 1건**만 띄운다.
5. 바뀐 필드만 최신 `reservations.json` 에 덮어써서 다시 올린다.

**시간대는 모두 Asia/Seoul(KST)** 이다. GitHub 의 예약 실행은 수 분~수십 분 늦을 수 있고, 이 지연은 `lead_minutes`(예정 시각보다 얼마나 일찍 띄울지)가 흡수한다. 늦게 띄워도 "언제까지 기다릴지"는 예정 시각 기준이라 달라지지 않는다.

### video 예약 — 특정 영상 한 번

- 조건: `scheduled_at − lead_minutes` 이후이고 `dispatched_at` 이 비어 있으면 띄운다.
- 띄울 때: `video_id` 로 실행하고, 라이브 시작을 `scheduled_at + (wait_minutes − lead_minutes)` 까지 기다린다.
  `wait_minutes` 기본값은 `lead_minutes + 90` → 예정보다 **90분 늦게 시작해도** 녹음한다.
- 다른 녹음이 실행 중이면 보류하고 다음 실행 때 다시 본다.
- 실행하면 `dispatched_at`, `session_id` 를 기록한다.
- `scheduled_at + max_minutes + 60분` 이 지나면 목록에서 지운다.

### weekly 예약 — 요일·시각 반복

- 조건: `대상 시각 − lead_minutes ≤ 지금 < 대상 시각 + wait_minutes` 이고 그 회차(`last_dispatched_date`)를 아직 처리하지 않았으면 띄운다.
  구간으로 판단하므로 자정을 넘는 경우(00:10 예배를 전날 23:40 에 실행, 23:50 예배를 다음 날 00:20 에 실행)도 맞게 동작한다.
- 어떤 영상을 녹음할지: `upcoming.json` 에서 **대상 시각 ±45분 안의 예정 라이브 중 가장 가까운 것**을 고른다(후보는 로그에 남는다).
  없으면 채널 `/live` 주소로 대체한다.
- 같은 영상을 video 예약이 이미 실행했으면 중복으로 띄우지 않고 그 회차를 처리한 것으로 기록한다. 아직 실행 전이면 video 예약에 맡긴다.
- 다른 녹음이 실행 중이면 구간 안에서 보류한다. 구간이 지나면 그 회차는 건너뛴다.
- 실행하면 `last_dispatched_date`, `last_dispatched_at`, `last_session_id`, `last_video_id` 를 기록한다.
- 라이브 시작은 `대상 시각 + wait_minutes` 까지 기다린다. 기본 60분이므로, 1시간 넘게 늦는 일이 있으면 `wait_minutes` 를 늘린다.

### 모의 실행

Actions 탭 → **dispatcher** → Run workflow → `dry_run` 체크. 녹음을 띄우지 않고 R2 에 쓰지 않으며 판정 결과만 로그에 남긴다.

## R2 에 있는 파일

| 키 | 쓰는 쪽 | 읽는 쪽 | 내용 |
| --- | --- | --- | --- |
| `recordings/{YYYY-MM-DD}_{HHMM}_{session_id}.mp3` | 녹음 | 앱 | 녹음 파일. 메타데이터 `title`(퍼센트 인코딩, 앞 100자) · `duration`(초) · `bytes` |
| `recordings/{YYYY-MM-DD}_{HHMM}_{session_id}.json` | 녹음 | 앱 | 사이드카 |
| `reservations.json` | **앱**(예약 추가·수정·삭제), 발사기(실행 기록·지난 예약 정리) | 발사기, 앱 | 예약 목록 |
| `upcoming.json` | 발사기 | 앱 | 채널의 예정·진행 중 라이브 |
| `state/current.json` | 녹음 | 앱 | 지금 실행 중인 녹음의 단계. 끝나면 삭제 |

날짜·시각은 KST 다.

### 사이드카

```json
{
  "title": "주일 2부 예배",
  "started_at": "2026-11-22T10:55:03+09:00",
  "duration_sec": 4312,
  "bytes": 34496000,
  "session_id": "r-20261122-1050-3fa1",
  "key": "recordings/2026-11-22_1055_r-20261122-1050-3fa1.mp3",
  "status": "complete",
  "stop_reason": "stream_ended",
  "video_id": "XXXXXXXXXXX",
  "reservation_id": "w1"
}
```

- `started_at`: 실행(대기 포함)이 시작된 시각. `status`: `complete`(녹음 step 성공) / `partial`(실패·취소 후 남은 부분 파일)

### reservations.json

```json
{
  "items": [
    {
      "id": "v-20261129",
      "kind": "video",
      "video_id": "XXXXXXXXXXX",
      "title": "주일 2부 예배",
      "scheduled_at": "2026-11-29T11:00:00+09:00",
      "lead_minutes": 30,
      "max_minutes": 150,
      "dispatched_at": null
    },
    {
      "id": "w-sun-2",
      "kind": "weekly",
      "weekday": 0,
      "time": "11:00",
      "tz": "Asia/Seoul",
      "title": "주일 2부 예배",
      "lead_minutes": 10,
      "wait_minutes": 60,
      "max_minutes": 150,
      "last_dispatched_date": null
    }
  ]
}
```

| 필드 | 쓰는 쪽 | 설명 |
| --- | --- | --- |
| `id` | 앱 | 영문·숫자·`-`·`_` 1~64자. 목록 안에서 유일해야 한다 |
| `kind` | 앱 | `video` / `weekly` |
| `video_id`, `scheduled_at` | 앱 | video 전용. `scheduled_at` 은 시간대가 붙은 ISO 8601 |
| `weekday`, `time`, `tz` | 앱 | weekly 전용. `weekday` 0=일 … 6=토, `time` 은 `HH:MM`, `tz` 는 `Asia/Seoul` |
| `title` | 앱 | 공개 로그에 보인다 |
| `lead_minutes` | 앱 | 기본 video 30 / weekly 10 |
| `wait_minutes` | 앱 | 기본 video `lead + 90` / weekly 60 |
| `max_minutes` | 앱 | 기본 150 |
| `dispatched_at`, `session_id` | **발사기** | video 를 실행한 시각과 그 녹음의 세션 id |
| `last_dispatched_date`, `last_dispatched_at`, `last_session_id`, `last_video_id` | **발사기** | weekly 의 마지막 회차 |

형식이 틀린 항목은 경고만 남기고 건너뛴다. 파일 전체가 틀리면(`items` 배열 없음) 아무것도 바꾸지 않고 실패한다.

**동시 수정에 대한 전제(앱이 지켜야 할 것).** 잠금은 없다. 발사기는 쓰기 직전에 파일을 다시 받아 자기가 바꾼 필드만 `id` 기준으로 덮어쓰고, 지난 예약은 읽었을 때와 내용이 같을 때만 지운다. 그래도 "다시 받기 ~ 올리기" 사이 몇 초 동안 앱이 쓰면 한쪽 변경이 사라질 수 있다. 앱은:

- 저장 직전에 최신본을 다시 읽고 그 위에 변경을 적용한다(화면에 띄워 둔 오래된 사본을 통째로 올리지 않는다).
- 발사기 소유 필드(위 표의 **발사기** 행)는 받은 값을 그대로 돌려 쓴다. 지우거나 `null` 로 되돌리면 같은 예약이 다시 실행된다.
- 이미 실행된 video 예약의 시각을 바꿔 다시 녹음하려면 새 `id` 로 추가한다.
- 발사기가 지난 video 예약을 지울 수 있으므로, 저장 후 항목이 사라져 있어도 오류로 보지 않는다.

### upcoming.json

```json
{
  "updated_at": "2026-11-29T10:37:12+09:00",
  "items": [
    { "video_id": "XXXXXXXXXXX", "title": "…", "scheduled_at": "2026-11-29T11:00:00+09:00", "scheduled_ts": 1795917600, "status": "upcoming" }
  ]
}
```

- `status`: `upcoming` / `live`. `scheduled_ts` 는 같은 시각의 epoch(초). 예정 시각을 얻지 못하면 둘 다 `null`.
- 유튜브 조회를 줄이기 위해 이미 아는 영상의 시각은 재사용하고 매 시 첫 실행에서만 전부 다시 조회한다. 따라서 방송 시각이 바뀌면 반영에 최대 1시간쯤 걸린다.
- 조회에 실패하면 이전 파일을 그대로 둔다. `updated_at` 이 오래됐으면 목록이 낡았다는 뜻이다.

### state/current.json

```json
{
  "phase": "waiting",
  "session_id": "r-20261129-1037-3fa1",
  "title": "주일 2부 예배",
  "video_id": "XXXXXXXXXXX",
  "reservation_id": "v-20261129",
  "run_id": "45052788772",
  "started_at": "2026-11-29T10:38:02+09:00",
  "updated_at": "2026-11-29T10:43:02+09:00"
}
```

- `phase`: `waiting`(라이브 시작 대기) / `recording`. `updated_at` 은 단계가 바뀔 때와 5분마다 갱신된다.
- 녹음이 끝나면(성공·실패·취소) 지운다. 다만 러너가 강제 종료되면 남을 수 있으므로,
  **앱은 같은 `session_id` 의 실행이 진행 중일 때만 이 파일을 믿는다.**

## Secrets

| 이름 | 용도 |
| --- | --- |
| `R2_ACCOUNT_ID` | R2 엔드포인트 `https://{id}.r2.cloudflarestorage.com` |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | R2 API 토큰(객체 읽기·쓰기·삭제) |
| `R2_BUCKET` | 버킷 이름 |
| `YT_COOKIES` (선택) | 봇 차단 대응용 Netscape 형식 cookies.txt 내용 |
| `GH_VARS_TOKEN` (선택) | `STOP_SIGNAL` 조회용 토큰. 아래 "원격 정지" 참고 |

## Variables

| 이름 | 기본값 | 설명 |
| --- | --- | --- |
| `LIVE_URL` | (비움) | 채널 라이브 주소(`https://www.youtube.com/@채널/live`). 예정 라이브 목록의 채널 주소도 여기서 유도한다 |
| `MAX_MINUTES` | `120` | 녹음 시작 후 최대 녹음 시간(분). 실행 입력 `max_minutes` 가 있으면 그쪽이 우선 |
| `YTDLP_FORMAT` | `bestaudio/best` | yt-dlp `-f` 값 |
| `YTDLP_EXTRA_ARGS` | (비움) | yt-dlp 추가 인자. 따옴표 인용 가능 |
| `STOP_SIGNAL` | — | 앱이 정지할 세션 id 를 써넣는다 |

## 수동 실행

GitHub 리포 → **Actions** 탭 → 왼쪽 **record** → **Run workflow** → `session_id`(아무 고유 문자열, 예: `test-1`)와 필요한 입력을 넣고 실행한다.

CLI:

```bash
# 지금 방송 중인 라이브를 5분만
gh workflow run record.yml -R syrccm/symusic-recorder -f session_id=test-1 -f max_minutes=5 -f title="테스트"

# 예정 라이브가 시작되기를 최대 60분 기다렸다가 녹음
gh workflow run record.yml -R syrccm/symusic-recorder -f session_id=test-2 -f video_id=XXXXXXXXXXX -f wait_minutes=60
```

수동으로 멈추려면 리포 변수 `STOP_SIGNAL` 을 그 `session_id` 로 바꾼다(대기 중에도 멈춘다).

```bash
gh variable set STOP_SIGNAL -R syrccm/symusic-recorder --body test-1
```

## 원격 정지 (STOP_SIGNAL)

녹음·대기 중 10초마다 `GET /repos/{owner}/{repo}/actions/variables/STOP_SIGNAL` 을 호출한다.
기본은 워크플로의 `GITHUB_TOKEN` 을 쓴다. 로그에 `STOP_SIGNAL 조회 실패(HTTP 403)` 경고가 보이면 기본 토큰으로는 변수를 읽을 수 없다는 뜻이니,
이 리포에 **Variables: Read** 권한만 준 fine-grained PAT 를 시크릿 `GH_VARS_TOKEN` 으로 등록한다(워크플로가 자동으로 그 토큰을 쓴다).
조회가 실패해도 녹음은 계속되며 방송 종료 또는 `max_minutes` 에서 끝난다.

## 봇 차단 시 대응 순서

yt-dlp 로그에 `Sign in to confirm you're not a bot` 등이 보이고 녹음이 `no_data`/`wait_timeout` 으로 끝나면 순서대로 시도한다.

1. 변수 `YTDLP_EXTRA_ARGS` 에 다음을 넣는다.
   ```
   --extractor-args "youtube:player_client=tv"
   ```
2. 시크릿 `YT_COOKIES` 에 **별도 계정**(개인 계정 말고 녹음 전용)으로 로그인해 내보낸 cookies.txt 내용을 넣는다. 있으면 자동으로 `--cookies` 가 붙는다.
3. 로컬 PC 에서 실행한다(ffmpeg, yt-dlp, jq 필요. Linux/macOS/WSL).
   ```bash
   LIVE_URL="https://www.youtube.com/watch?v=..." SESSION_ID=local-1 MAX_MINUTES=120 bash scripts/record.sh
   ```
   `GH_TOKEN` 이 없으면 STOP_SIGNAL 감시는, R2 변수가 없으면 진행 상태 기록은 생략된다. Ctrl+C 또는 `MAX_MINUTES` 로 끝나며 결과 `out.mp3` 는 직접 R2 에 올린다.

발사기의 예정 라이브 조회가 차단되면 `upcoming.json` 이 갱신되지 않는다. 이때 video 예약은 그대로 동작하고, weekly 예약은 채널 `/live` 주소로 대체해 동작한다.

## 60일 비활성화 대비

공개 리포는 60일간 커밋이 없으면 GitHub 가 `schedule` 워크플로를 자동으로 끈다.
발사기는 실행 때마다(schedule·Worker·수동 모두, 모의 실행 제외) 마지막 커밋 날짜를 보고 **50일을 넘겼으면 빈 커밋**(`chore: 예약 워크플로 유지…`)을 `main` 에 올린다.
그래도 꺼졌다면 Actions 탭 → dispatcher → **Enable workflow** 로 다시 켠다.

## R2 수명 주기

녹음 파일은 7일 뒤 자동 삭제한다. Cloudflare 대시보드 → R2 → 버킷 → **Settings → Object lifecycle rules** 에서
**접두사 `recordings/`** 로 **Delete objects after 7 days** 규칙을 둔다.
접두사 없이 버킷 전체에 걸면 `reservations.json` 까지 7일 뒤 지워지므로 반드시 접두사를 지정한다. 이 설정은 리포가 아니라 버킷에 있다.

## 참고

- 러너의 yt-dlp 는 실행할 때마다 최신판을 받는다.
- 예약으로 띄운 녹음의 세션 id 는 `r-YYYYMMDD-HHmm-xxxx` 형식이다.
