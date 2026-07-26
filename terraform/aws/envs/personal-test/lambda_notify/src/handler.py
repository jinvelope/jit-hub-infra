import base64
import json
import logging
import os
import urllib.error
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")
SLACK_TIMEOUT_SECONDS = float(os.environ.get("SLACK_TIMEOUT_SECONDS", "5"))

NOTIFICATION_TYPE_ERROR_DETECTED = "error_detected"
NOTIFICATION_TYPE_ANALYSIS_COMPLETE = "analysis_complete"


def _build_error_detected_message(payload: dict) -> dict:
    cluster_name = payload.get("cluster_name", "unknown")
    failure_keyword = payload.get("failure_keyword", "unknown")
    log_snippet = payload.get("log_snippet", "")
    detected_at = payload.get("detected_at", "unknown")

    text = f"🚨 [{cluster_name}] 에러 감지: {failure_keyword}"
    blocks = [
        {"type": "section", "text": {"type": "mrkdwn", "text": text}},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*감지 시각*: {detected_at}\n*로그*:\n```{log_snippet}```",
            },
        },
    ]
    return {"text": text, "blocks": blocks}


def _build_analysis_complete_message(payload: dict) -> dict:
    cluster_name = payload.get("cluster_name", "unknown")
    failure_type = payload.get("failure_type", "unknown")
    dr_action_needed = payload.get("dr_action_needed", False)
    summary = payload.get("summary", "")
    response_time_sec = payload.get("response_time_sec", "unknown")
    analyzed_at = payload.get("analyzed_at", "unknown")

    if dr_action_needed:
        text = f"🚨 [{cluster_name}] 장애 감지: {failure_type} 발생"
        detail = (
            "AI 분석 결과, DR(재해복구) 전환을 권장합니다.\n\n"
            f"▸ 요약: {summary}\n"
            "▸ 확인 후 DR 전환 진행 여부를 결정해주세요."
        )
    else:
        text = f"✅ [{cluster_name}] 분석 완료: {failure_type} / DR 필요: {dr_action_needed}"
        detail = (
            f"*요약*: {summary}\n"
            f"*분석 시각*: {analyzed_at}\n"
            f"*응답 시간*: {response_time_sec}초"
        )

    blocks = [
        {"type": "section", "text": {"type": "mrkdwn", "text": text}},
        {"type": "section", "text": {"type": "mrkdwn", "text": detail}},
    ]
    return {"text": text, "blocks": blocks}


_MESSAGE_BUILDERS = {
    NOTIFICATION_TYPE_ERROR_DETECTED: _build_error_detected_message,
    NOTIFICATION_TYPE_ANALYSIS_COMPLETE: _build_analysis_complete_message,
}


def _parse_body(event: dict) -> dict:
    body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")
    return json.loads(body)


def _post_to_slack(message: dict) -> None:
    if not SLACK_WEBHOOK_URL:
        logger.warning("SLACK_WEBHOOK_URL이 설정되지 않아 Slack 전송을 건너뜀")
        return

    data = json.dumps(message).encode("utf-8")
    req = urllib.request.Request(
        SLACK_WEBHOOK_URL,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=SLACK_TIMEOUT_SECONDS) as resp:
        resp.read()


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    try:
        payload = _parse_body(event)
    except (json.JSONDecodeError, TypeError, ValueError, UnicodeDecodeError) as e:
        logger.error("요청 body 파싱 실패: %s | event=%s", e, event)
        return _response(200, {"status": "ignored", "reason": "invalid body"})

    notification_type = payload.get("notification_type")
    build_message = _MESSAGE_BUILDERS.get(notification_type)
    if build_message is None:
        logger.warning("알 수 없는 notification_type, 무시: %s", notification_type)
        return _response(200, {"status": "ignored", "reason": "unknown notification_type"})

    try:
        message = build_message(payload)
        _post_to_slack(message)
    except urllib.error.HTTPError as e:
        logger.error("Slack Webhook 호출 실패(HTTP %s): %s", e.code, e)
    except urllib.error.URLError as e:
        logger.error("Slack Webhook 호출 실패(연결/타임아웃): %s", e)
    except Exception:
        logger.exception("Slack 알림 처리 중 예기치 못한 오류 발생")

    return _response(200, {"status": "ok"})
