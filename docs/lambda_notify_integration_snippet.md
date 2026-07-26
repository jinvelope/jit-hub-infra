# Lambda-Slack 알림 연동 스니펫 (jit-hub-app 적용용)

이 문서는 `terraform/aws/envs/personal-test/lambda_notify/`에 구현한 Slack 알림 Lambda를
`jit-hub-app` 레포의 `services/sllm/app/poller.py`, `services/sllm/app/main.py`에서
호출하는 예시 코드입니다. 이 스니펫은 이미 jit-hub-app 레포에 실제로 반영 완료되었습니다 (poller.py, main.py 실제 코드 참고).

기존 두 파일의 스타일(httpx.AsyncClient, `httpx.ConnectError`/`TimeoutException`/`HTTPStatusError`를
개별적으로 잡아서 로그만 남기고 메인 흐름은 끊지 않는 에러 격리 패턴)을 그대로 따랐습니다.

## 공통: 환경변수

두 파일 모두 아래 환경변수를 추가로 읽습니다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `LAMBDA_NOTIFY_URL` | `""` (비활성) | Terraform output `notify_endpoint` 값. 비어있으면 알림 호출 자체를 건너뜀 |
| `LAMBDA_NOTIFY_TIMEOUT_SECONDS` | `3` | Lambda 호출 타임아웃(초), 3~5초 권장 |

## ① poller.py — 에러 감지 시점 (`/analyze` 호출 전)

`app/poller.py`의 `FILTER_KEYWORDS`/`_KEYWORD_PATTERN` 바로 아래에 추가:

```python
from datetime import datetime, timezone

LAMBDA_NOTIFY_URL = os.environ.get("LAMBDA_NOTIFY_URL", "")
LAMBDA_NOTIFY_TIMEOUT_SECONDS = float(os.environ.get("LAMBDA_NOTIFY_TIMEOUT_SECONDS", "3"))


def _matched_keyword(entry: LogEntry) -> str:
    match = _KEYWORD_PATTERN.search(entry.message)
    return match.group(0) if match else "unknown"


async def _notify_error_detected(entry: LogEntry) -> None:
    if not LAMBDA_NOTIFY_URL:
        return

    payload = {
        "notification_type": "error_detected",
        "cluster_name": entry.cluster_name,
        "failure_keyword": _matched_keyword(entry),
        "log_snippet": entry.message[:500],
        "detected_at": datetime.now(timezone.utc).isoformat(),
    }
    try:
        async with httpx.AsyncClient(timeout=LAMBDA_NOTIFY_TIMEOUT_SECONDS) as client:
            resp = await client.post(LAMBDA_NOTIFY_URL, json=payload)
            resp.raise_for_status()
    except httpx.ConnectError as e:
        logger.warning(
            "Slack 알림(에러 감지) 연결 실패, 무시하고 계속 진행 (cluster=%s pod=%s): %s",
            entry.cluster_name, entry.pod, e,
        )
    except httpx.TimeoutException as e:
        logger.warning(
            "Slack 알림(에러 감지) 응답 시간 초과, 무시하고 계속 진행 (cluster=%s pod=%s): %s",
            entry.cluster_name, entry.pod, e,
        )
    except httpx.HTTPStatusError as e:
        logger.warning(
            "Slack 알림(에러 감지) 호출 실패(HTTP %s), 무시하고 계속 진행 (cluster=%s pod=%s): %s",
            e.response.status_code, entry.cluster_name, entry.pod, e,
        )
```

`poll_once()`의 기존 루프에서, "새 장애 로그 감지" 로그 다음 줄 — `_send_to_analyze(entry)` 호출
**전**에 추가:

```python
    for entry in new_matches:
        logger.warning(
            "새 장애 로그 감지 (cluster=%s pod=%s): %s",
            entry.cluster_name, entry.pod, entry.message[:120],
        )

        await _notify_error_detected(entry)  # ① 에러 감지 알림 — /analyze 호출 전

        try:
            analyzed = await _send_to_analyze(entry)
        except httpx.ConnectError as e:
            ...
```

`_notify_error_detected`는 내부에서 이미 모든 예외를 잡아 로그만 남기므로, 실패해도
`_send_to_analyze` 이후의 메인 로직(분석 요청)은 그대로 진행됩니다.

## ② main.py — `/analyze` 완료 후

**사전 조건**: `AnalyzeRequest`에 `cluster_name` 선택 필드가 추가됨
(jit-hub-app `feat/sllm-notify-integration` 브랜치, 커밋 완료 — 기존 `log_text`만 보내는
요청과 호환됨). `poller.py`의 `_send_to_analyze`가 `entry.cluster_name`을 함께 보내도록 연결하는 작업도 완료되었습니다.

```python
class AnalyzeRequest(BaseModel):
    log_text: str
    cluster_name: str | None = None
```

`app/main.py` 상단에 환경변수/헬퍼 추가:

```python
import time
from datetime import datetime, timezone

LAMBDA_NOTIFY_URL = os.environ.get("LAMBDA_NOTIFY_URL", "")
LAMBDA_NOTIFY_TIMEOUT_SECONDS = float(os.environ.get("LAMBDA_NOTIFY_TIMEOUT_SECONDS", "3"))

# dr_action_needed 판단 기준 (팀 확정, 7/24 변경): OOMKilled/DiskPressure/NetworkTimeout이면 DR 전환 필요
_DR_ACTION_FAILURE_TYPES = {"OOMKilled", "DiskPressure", "NetworkTimeout"}


async def _notify_analysis_complete(
    cluster_name: str, result: AnalyzeResponse, response_time_sec: float
) -> None:
    if not LAMBDA_NOTIFY_URL:
        return

    payload = {
        "notification_type": "analysis_complete",
        "cluster_name": cluster_name,
        "failure_type": result.failure_type,
        "dr_action_needed": result.failure_type in _DR_ACTION_FAILURE_TYPES,
        "summary": result.root_cause,
        "response_time_sec": round(response_time_sec, 2),
        "analyzed_at": datetime.now(timezone.utc).isoformat(),
    }
    try:
        async with httpx.AsyncClient(timeout=LAMBDA_NOTIFY_TIMEOUT_SECONDS) as client:
            resp = await client.post(LAMBDA_NOTIFY_URL, json=payload)
            resp.raise_for_status()
    except httpx.ConnectError as e:
        logger.warning("Slack 알림(분석 완료) 연결 실패, 무시: %s", e)
    except httpx.TimeoutException as e:
        logger.warning("Slack 알림(분석 완료) 응답 시간 초과, 무시: %s", e)
    except httpx.HTTPStatusError as e:
        logger.warning("Slack 알림(분석 완료) 호출 실패(HTTP %s), 무시: %s", e.response.status_code, e)
```

`/analyze` 핸들러에서 응답 반환 직전에 호출 (경과 시간 측정 포함):

```python
@app.post("/analyze", response_model=AnalyzeResponse)
async def analyze(req: AnalyzeRequest) -> AnalyzeResponse:
    start = time.monotonic()

    prompt = PROMPT_TEMPLATE.format(
        log_text=req.log_text,
        failure_types=", ".join(FAILURE_TYPES),
    )

    first = await _call_ollama(prompt)

    if not _has_bad_pattern(first):
        result = first
    else:
        logger.warning("응답 필드에 한자·코드성 패턴 감지, 재시도: %s", first.model_dump())
        retry = await _call_ollama(prompt)
        result = retry if not _has_bad_pattern(retry) else _build_degraded_response(first, retry)

    elapsed = time.monotonic() - start
    await _notify_analysis_complete(req.cluster_name or "unknown", result, elapsed)  # ② 분석 완료 알림

    return result
```

`_notify_analysis_complete` 역시 실패해도 내부에서 예외를 모두 잡으므로 `/analyze`의
응답(`result`)에는 영향을 주지 않습니다.

## 로컬 테스트 방법 (실제 jit-hub-app 레포 적용 시)

Lambda/API Gateway 없이 로컬에서 확인하려면 `httpx` mock 또는 `respx` 같은 라이브러리로
`LAMBDA_NOTIFY_URL`을 가짜 엔드포인트로 두고, `httpx.MockTransport`로 응답을 흉내내는 것을
권장합니다 (별도 패키지 설치 없이 `httpx.MockTransport`만으로 가능). 실제 Terraform 배포 후에는
`terraform output notify_endpoint` 값을 그대로 `LAMBDA_NOTIFY_URL`에 넣으면 됩니다.
