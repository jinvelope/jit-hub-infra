# =============================================================================
# terraform/utils/harbor-tunnel/variables.tf
# =============================================================================

# --- Cloudflare 인증/식별 ------------------------------------------------------
variable "cloudflare_api_token" {
  description = "Cloudflare API Token (Tunnel + DNS 편집 권한 필요)"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID (leechs.shop 의 Zone ID)"
  type        = string
}

# --- 도메인 --------------------------------------------------------------------
variable "domain_name" {
  description = "루트 도메인 (예: leechs.shop). harbor 서브도메인이 이 위에 생성됨 → harbor.leechs.shop"
  type        = string
}

# --- 온프레미스 클러스터 접속 (connector 배포 대상) -----------------------------
variable "onprem_kubeconfig" {
  description = "온프레미스 kubeconfig 경로"
  type        = string
  default     = "~/.kube/config"
}

variable "onprem_context" {
  description = "온프레미스 kubectl context 이름 (기존 프로젝트와 동일)"
  type        = string
  default     = "kubernetes-admin@kubernetes"
}

# --- Harbor 대상 ---------------------------------------------------------------
variable "harbor_private_endpoint" {
  description = "cloudflared Pod 가 접근할 Harbor 내부 주소 (HTTP). Harbor 서버 사설 IP:포트"
  type        = string
  default     = "http://172.16.8.200:80"
}

variable "harbor_subdomain" {
  description = "Harbor 서브도메인 레코드 이름 (harbor → harbor.leechs.shop)"
  type        = string
  default     = "harbor"
}
