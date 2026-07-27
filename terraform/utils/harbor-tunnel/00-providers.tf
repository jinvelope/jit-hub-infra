# =============================================================================
# terraform/utils/harbor-tunnel/00-providers.tf
# Harbor 전용 Cloudflare Tunnel (서비스 터널 jit-hub-tunnel 과 완전 분리)
#
# 목적:
#   - Harbor(172.16.8.200, HTTP:80)를 harbor.unzipp.cloud (HTTPS) 로 공개 노출
#   - 이미지 pull 경로를 단일 도메인으로 통일 (eks-a / eks-b / onprem 공용)
#   - DR 스위칭용 서비스 터널과 state / 터널 / connector 를 모두 분리
#
# 특징:
#   - 초기 1회 terraform apply 후 그대로 유지 (앱 배포/DR 사이클과 무관)
#   - Harbor 자체는 자동화하지 않음 (온프레 별도 노드에서 수동 관리)
#   - connector replica = 1 고정 (온프레 상시 서빙)
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }

  # --- 독립 state (local backend) ---------------------------------------------
  # 기존 프로젝트가 모두 local backend 를 사용하므로 동일하게 local 로 둔다.
  # 별도 폴더이므로 terraform.tfstate 가 자연히 분리된다.
  backend "local" {
    path = "terraform.tfstate"
  }
}

# --- Cloudflare provider -------------------------------------------------------
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# --- 온프레미스(VMware k8s) 클러스터: connector(cloudflared) 배포 대상 ----------
# 기존 프로젝트와 동일한 컨텍스트 사용 (00-providers.tf 확인됨)
provider "kubernetes" {
  config_path    = var.onprem_kubeconfig
  config_context = var.onprem_context
}

provider "helm" {
  kubernetes {
    config_path    = var.onprem_kubeconfig
    config_context = var.onprem_context
  }
}
