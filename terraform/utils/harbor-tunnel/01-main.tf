# =============================================================================
# terraform/utils/harbor-tunnel/01-main.tf
# Harbor 전용 터널 + DNS(harbor.unzipp.cloud) + 온프레 상시 connector
#
# 모듈 경로 주의:
#   이 파일이 terraform/utils/harbor-tunnel/ 에 위치한다고 가정.
#   shared 모듈까지 상대경로: ../../shared/modules/...
#   (terraform/utils/harbor-tunnel  ->  terraform/shared/modules)
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Harbor 전용 Cloudflare Tunnel + DNS(CNAME) + tunnel_config(ingress_rule)
#    - 서비스 터널(jit-hub-tunnel)과 이름/ID/DNS 모두 분리
#    - dns_records = ["harbor"]  ->  harbor.unzipp.cloud CNAME 생성
#    - ingress_rule: harbor.unzipp.cloud  ->  cloudflared Pod 가 Harbor 사설IP로 전달
# -----------------------------------------------------------------------------
module "harbor_tunnel" {
  source = "../../shared/modules/cloudflared"

  cloudflare_account_id = var.cloudflare_account_id
  cloudflare_zone_id    = var.cloudflare_zone_id

  tunnel_name = "harbor-tunnel" # ★ 서비스 터널과 분리된 전용 터널
  domain_name = var.domain_name # unzipp.cloud

  # harbor 서브도메인만 생성 (서비스용 @/argocd/grafana 와 무관)
  dns_records = [var.harbor_subdomain] # ["harbor"] -> harbor.unzipp.cloud

  ingress_rules = [
    {
      hostname = "${var.harbor_subdomain}.${var.domain_name}" # harbor.unzipp.cloud
      # cloudflared Pod 는 온프레망 안에 있으므로 Harbor 사설 IP 로 직접 전달.
      # Cloudflare 가 TLS 종단(HTTPS) -> 터널 내부는 HTTP 로 Harbor 에 전달.
      service = var.harbor_private_endpoint # http://172.16.8.200:80
    }
  ]
}

# -----------------------------------------------------------------------------
# 2. Harbor 터널 전용 connector (cloudflared Deployment) — 온프레 상시 1개
#    - 서비스 connector(namespace=cloudflared)와 다른 namespace 사용
#    - replicas = 1 고정 : DR 토글(서비스 터널)과 완전 독립
# -----------------------------------------------------------------------------
module "harbor_connector" {
  source = "../../shared/modules/cloudflare-prod"

  namespace        = "harbor-tunnel"        # ★ 서비스 connector 와 분리
  create_namespace = true
  secret_name      = "harbor-tunnel-token"
  tunnel_token     = module.harbor_tunnel.tunnel_token
  replicas         = 1                       # ★ 상시 1 (Harbor pull 항상 가능)

  depends_on = [module.harbor_tunnel]
}
