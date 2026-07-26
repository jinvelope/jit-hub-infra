# terraform/aws/envs/personal-test/lambda_notify/01-main.tf

locals {
  function_name = "sllm-notify-slack"
}

# ---------------------------------------------------------
# 1. Lambda 함수 패키징 (src/handler.py → zip)
# ---------------------------------------------------------
# 외부 라이브러리 없이 표준 urllib만 쓰므로 레이어/의존성 설치 없이 단일 파일만 압축하면 된다.
data "archive_file" "notify" {
  type        = "zip"
  source_file = "${path.module}/src/handler.py"
  output_path = "${path.module}/build/handler.zip"
}

# ---------------------------------------------------------
# 2. Lambda 실행 역할 (IAM) - CloudWatch Logs 전용 최소 권한
# ---------------------------------------------------------
resource "aws_iam_role" "notify_exec" {
  name = "sllm-notify-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "notify" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 14
}

# 이 함수의 로그 그룹에만 쓰기 가능하도록 범위를 좁힌 최소 권한 정책
resource "aws_iam_role_policy" "notify_logs" {
  name = "sllm-notify-lambda-logs"
  role = aws_iam_role.notify_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.notify.arn}:*"
      }
    ]
  })
}

# ---------------------------------------------------------
# 3. Lambda 함수
# ---------------------------------------------------------
resource "aws_lambda_function" "notify" {
  function_name = local.function_name
  role          = aws_iam_role.notify_exec.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  timeout       = 5
  memory_size   = 128

  filename         = data.archive_file.notify.output_path
  source_code_hash = data.archive_file.notify.output_base64sha256

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }

  depends_on = [aws_cloudwatch_log_group.notify]
}

# ---------------------------------------------------------
# 4. API Gateway (HTTP API) - POST /notify
# ---------------------------------------------------------
resource "aws_apigatewayv2_api" "notify" {
  name          = "sllm-notify-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "notify" {
  api_id                 = aws_apigatewayv2_api.notify.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.notify.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "notify" {
  api_id    = aws_apigatewayv2_api.notify.id
  route_key = "POST /notify"
  target    = "integrations/${aws_apigatewayv2_integration.notify.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.notify.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notify.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.notify.execution_arn}/*/*"
}
