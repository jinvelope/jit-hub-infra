# shared/modules/cloudflared/connector/variables.tf

variable "namespace" {
  type    = string
  default = "cloudflared"
}

variable "create_namespace" {
  type    = bool
  default = true
}

variable "secret_name" {
  type    = string
  default = "cloudflared-token"
}

variable "tunnel_token" {
  type      = string
  sensitive = true
}

variable "replicas" {
  type        = number
  default     = null
  description = "값을 넘기면 이 모듈이 Deployment까지 직접 생성한다 (예: harbor_connector). null이면 Secret만 생성하고 Deployment는 Helm/ArgoCD가 담당한다 (서비스용 cloudflared)."
}

variable "cloudflared_image" {
  type    = string
  default = "cloudflare/cloudflared:2024.11.0"
}