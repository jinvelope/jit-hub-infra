variable "aws_region" {
  description = "Lambda/API Gateway를 배포할 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL (Lambda 환경변수 SLACK_WEBHOOK_URL로 주입됨)"
  type        = string
  sensitive   = true
}
