# lambda_notify

Lambda-Slack 알림(sLLM 장애 감지/분석 완료) Terraform 레이어. `prod-region-a`, `dr-region-b`와
별도의 tfstate를 쓰는 독립 레이어입니다.

## 개인 계정에서 테스트하는 법

이 레이어는 각자 자신의 AWS 계정에 독립적으로 배포해서 테스트할 수 있습니다.
(provider가 특정 계정을 하드코딩하지 않고, backend도 local이라 서로 충돌하지 않습니다)

1. `cd terraform/aws/envs/personal-test/lambda_notify`
2. `cp terraform.tfvars.example terraform.tfvars`
3. `terraform.tfvars`에 Slack Webhook URL 입력
   (팀 공용 웹훅 URL — 디스코드에서 공유받으세요. `#sllm-알림` 채널로 전송됩니다)
4. `terraform init && terraform apply`
5. 출력된 `notify_endpoint`를 poller.py/main.py의 `LAMBDA_NOTIFY_URL` 환경변수에 설정
6. 테스트 후 개인 정리: `terraform destroy`

## 주의사항

- `terraform.tfvars`, `terraform.tfstate`, `.terraform/`는 `.gitignore`에 포함되어 있어 커밋되지 않습니다.
- Slack Webhook URL은 절대 커밋하거나 코드에 하드코딩하지 마세요.
- 현재는 각자 개인 AWS 계정에 배포하는 임시 구조이며,
  추후 jit-hub-app의 CI/CD 패턴(GitHub Actions + Secrets)처럼
  팀 공용 계정에 자동 배포하는 방식으로 전환 가능합니다.
