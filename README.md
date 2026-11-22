# symusic-recorder

유튜브 라이브(예배 실황)를 GitHub Actions 러너에서 mp3(64kbps 모노)로 녹음해 Cloudflare R2 비공개 버킷에 올린다.
시작과 종료는 symusic 앱(Vercel API)이 `workflow_dispatch` 와 리포 변수로 제어한다.

## 구조

```
.github/workflows/record.yml     녹음 → R2 업로드 (workflow_dispatch)
.github/workflows/scheduled.yml  예약 녹음 뼈대 (cron 비활성)
scripts/record.sh                yt-dlp → ffmpeg 녹음 + 정지 감시
```

흐름:

1. 앱이 `session_id` 를 만들어 `record.yml` 을 dispatch 한다.
2. `scripts/record.sh` 가 `yt-dlp → (FIFO) → ffmpeg` 로 `out.mp3` 를 쓴다.
3. 아래 중 하나가 일어나면 yt-dlp 를 끝내고 ffmpeg 가 파일을 정상 마감한다.
   - 리포 변수 `STOP_SIGNAL` 값이 이 실행의 `session_id` 와 같아짐 (10초마다 확인)
   - `MAX_MINUTES` 경과
   - 방송 종료
4. R2 에 업로드한다. 녹음 step 이 실패·취소돼도 부분 mp3 가 있으면 올린다. 아티팩트는 쓰지 않는다.

동시 실행은 1건이다(`concurrency: record`). 녹음 중에 새로 dispatch 하면 대기하며, 대기 중인 실행이 이미 있으면 그 실행은 새 것으로 교체된다.

## R2 에 올라가는 것

| 키 | 내용 |
| --- | --- |
| `recordings/{YYYY-MM-DD}_{HHMM}_{session_id}.mp3` | 녹음 파일. 메타데이터 `title`(퍼센트 인코딩, 앞 100자) · `duration`(초) · `bytes` |
| `recordings/{YYYY-MM-DD}_{HHMM}_{session_id}.json` | 사이드카 |

날짜·시각은 녹음 시작 시점의 KST 다. 사이드카 예:

```json
{
  "title": "주일 2부 예배",
  "started_at": "2026-11-22T10:55:03+09:00",
  "duration_sec": 4312,
  "bytes": 34496000,
  "session_id": "abc123",
  "key": "recordings/2026-11-22_1055_abc123.mp3",
  "status": "complete",
  "stop_reason": "stop_signal"
}
```

- `status`: `complete`(녹음 step 성공) / `partial`(실패·취소 후 남은 부분 파일)
- `stop_reason`: `stop_signal` · `max_minutes` · `stream_ended` · `no_data` · `cancelled`

## Secrets

| 이름 | 용도 |
| --- | --- |
| `R2_ACCOUNT_ID` | R2 엔드포인트 `https://{id}.r2.cloudflarestorage.com` |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | R2 API 토큰 |
| `R2_BUCKET` | 버킷 이름 |
| `YT_COOKIES` (선택) | 봇 차단 대응용 Netscape 형식 cookies.txt 내용 |
| `GH_VARS_TOKEN` (선택) | `STOP_SIGNAL` 조회용 토큰. 아래 "원격 정지" 참고 |

## Variables

| 이름 | 기본값 | 설명 |
| --- | --- | --- |
| `LIVE_URL` | (비움) | 라이브 주소. 비어 있으면 실행 시 `live_url` 입력이 필수 |
| `MAX_MINUTES` | `120` | 최대 녹음 시간(분). 실행 입력 `max_minutes` 가 있으면 그쪽이 우선. 상한 330 |
| `YTDLP_FORMAT` | `bestaudio/best` | yt-dlp `-f` 값 |
| `YTDLP_EXTRA_ARGS` | (비움) | yt-dlp 추가 인자. 따옴표 인용 가능 |
| `STOP_SIGNAL` | — | 앱이 정지할 세션 id 를 써넣는다 |

## 수동 실행

GitHub 리포 → **Actions** 탭 → 왼쪽 **record** → **Run workflow** → `session_id`(아무 고유 문자열, 예: `test-1`)와 필요하면 `live_url` · `max_minutes` · `title` 을 넣고 실행한다.

CLI:

```bash
gh workflow run record.yml -R syrccm/symusic-recorder \
  -f session_id=test-1 -f live_url="https://www.youtube.com/watch?v=..." -f max_minutes=5 -f title="테스트"
```

수동으로 멈추려면 리포 변수 `STOP_SIGNAL` 을 그 `session_id` 로 바꾼다.

```bash
gh variable set STOP_SIGNAL -R syrccm/symusic-recorder --body test-1
```

## 원격 정지 (STOP_SIGNAL)

녹음 중 10초마다 `GET /repos/{owner}/{repo}/actions/variables/STOP_SIGNAL` 을 호출한다.
기본은 워크플로의 `GITHUB_TOKEN` 을 쓴다. 녹음 로그에 `STOP_SIGNAL 조회 실패(HTTP 403)` 경고가 보이면 기본 토큰으로는 변수를 읽을 수 없다는 뜻이니,
이 리포에 **Variables: Read** 권한만 준 fine-grained PAT 를 시크릿 `GH_VARS_TOKEN` 으로 등록한다(워크플로가 자동으로 그 토큰을 쓴다).
조회가 실패해도 녹음은 계속되며 `MAX_MINUTES` 에서 끝난다.

## 봇 차단 시 대응 순서

시작 60초 후에도 `out.mp3` 가 0바이트면 녹음 step 이 `exit 1` 로 끝난다. yt-dlp 로그에 `Sign in to confirm you're not a bot` 등이 보이면 순서대로 시도한다.

1. 변수 `YTDLP_EXTRA_ARGS` 에 다음을 넣는다.
   ```
   --extractor-args "youtube:player_client=tv"
   ```
2. 시크릿 `YT_COOKIES` 에 **별도 계정**(개인 계정 말고 녹음 전용)으로 로그인해 내보낸 cookies.txt 내용을 넣는다. 있으면 자동으로 `--cookies` 가 붙는다.
3. 로컬 PC 에서 실행한다(ffmpeg, yt-dlp, jq 필요. Linux/macOS/WSL).
   ```bash
   LIVE_URL="https://www.youtube.com/watch?v=..." SESSION_ID=local-1 MAX_MINUTES=120 bash scripts/record.sh
   ```
   `GH_TOKEN` 이 없으면 STOP_SIGNAL 감시는 생략되고, Ctrl+C 또는 `MAX_MINUTES` 로 끝난다. 결과 `out.mp3` 는 직접 R2 에 올린다.

같은 0바이트 증상은 방송이 아직 시작되지 않았거나 주소가 틀렸을 때도 나온다. 로그의 yt-dlp 오류 문구로 구분한다.

## 예약 녹음

`scheduled.yml` 은 cron 이 주석 처리된 뼈대다. 주일 1·2·3부와 금요철야 자리만 잡혀 있고 시간은 예시다.
켜려면 `schedule` 블록과 `case` 문의 주석을 풀고 실제 시간을 UTC 로 바꿔 넣는다(KST − 9시간, 파일 상단 주석 참고).
예약 실행은 `LIVE_URL` 변수의 주소로 `record.yml` 을 dispatch 한다. Actions 탭에서 scheduled 를 수동 실행해도 같은 동작을 한다.

## R2 수명 주기

녹음 파일은 7일 뒤 자동 삭제한다. Cloudflare 대시보드 → R2 → 버킷 → **Settings → Object lifecycle rules** 에서
접두사 `recordings/`, **Delete objects after 7 days** 규칙을 추가한다. 이 설정은 리포가 아니라 버킷에 있다.

## 참고

- 비공개 리포의 Actions 무료 사용량(Free 플랜 월 2,000분)에 녹음 시간이 그대로 차감된다.
- 러너의 yt-dlp 는 실행할 때마다 pip 로 최신판을 받는다.
