# terraform/aws/envs/personal-test/lambda_notify/00-providers.tf
#
# prod-region-a / dr-region-b와 별도의 tfstate를 쓰는 독립 레이어.
# Lambda-Slack 알림 기능 검증/운영용으로, 다른 환경의 EKS/네트워크 리소스와 분리해서 관리한다.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
  required_version = ">= 1.8"
}

provider "aws" {
  region = var.aws_region
}
