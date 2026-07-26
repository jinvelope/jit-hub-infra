# jit-hub-app의 LAMBDA_NOTIFY_URL 환경변수(poller.py / main.py)에 넣을 값
# $default 스테이지의 invoke_url은 이미 끝에 "/"가 붙어있으므로 route 경로만 이어붙이면 됨
output "notify_endpoint" {
  description = "API Gateway invoke URL (POST {notify_endpoint} 로 알림 전송)"
  value       = "${aws_apigatewayv2_stage.default.invoke_url}notify"
}
