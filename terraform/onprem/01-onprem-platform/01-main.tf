# -------------------------------------------------------------------------------
# 1. Cloudflare Tunnel (전체 프로젝트 유일 — eks-a/onprem/eks-b 공용 multi origin)
# -------------------------------------------------------------------------------
module "cloudflared_tunnel" {
  source = "../../shared/modules/cloudflared"

  cloudflare_account_id = var.cloudflare_account_id
  cloudflare_zone_id    = var.cloudflare_zone_id
  tunnel_name             = "jit-hub-tunnel"
  domain_name              = var.domain_name
  dns_records              = ["@", "argocd", "grafana", "prometheus", "prometheus-ingest", "loki-ingest"]

  ingress_rules = [
    # 서비스 트래픽 (평시 eks-a, 장애시 onprem, DR시 eks-b — 오리진은 replica로 스위칭)
    {
      hostname = var.domain_name
      service  = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80"
    },
    # 관제용 (onprem 고정)
    {
      hostname = "argocd.${var.domain_name}"
      service  = "https://argocd-server.argocd.svc.cluster.local:443"
    },
    {
      hostname = "grafana.${var.domain_name}"
      service  = "http://onprem-monitoring-stack-grafana.monitoring.svc.cluster.local:80"
    },
    # Prometheus UI 직접 조회용 (사람이 브라우저로 확인하는 용도)
    {
      hostname = "prometheus.${var.domain_name}"
      service  = "http://onprem-monitoring-stack-ku-prometheus.monitoring.svc.cluster.local:9090"
    },
    # eks-a/eks-b → onprem 중앙 모니터링 수신 (charts/monitoring-stack의 ingest-ingress가 실제 라우팅)
    {
      hostname = "prometheus-ingest.${var.domain_name}"
      service  = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80"
    },
    {
      hostname = "loki-ingest.${var.domain_name}"
      service  = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80"
    }
  ]
}

# -------------------------------------------------------------------------------
# 2. Cloudflared 접속용 Secret 생성 (onprem 자체)
#    Deployment는 charts/cloudflared(Helm/ArgoCD, gitops/values/onprem/cloudflared-values.yaml)가 담당
# -------------------------------------------------------------------------------
module "cloudflared_connector" {
  source = "../../shared/modules/cloudflare-prod"

  namespace    = "cloudflared"
  secret_name  = "cloudflared-token"
  tunnel_token = module.cloudflared_tunnel.tunnel_token

  depends_on = [module.cloudflared_tunnel]
}

# -------------------------------------------------------------------------------
# K8s 코어 인프라 설치 (Ingress 및 ArgoCD)
# -------------------------------------------------------------------------------

# Ingress Nginx 설치
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.0"
  namespace        = "ingress-nginx"
  create_namespace = true
}

# ArgoCD 설치
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.1.2"
  namespace        = "argocd"
  create_namespace = true
  values = [
    file("${path.module}/argocd/my-values.yaml")
  ]
    set {
    name  = "configs.secret.argocdServerAdminPassword"
    # htpasswd (bcrypt) 형태로 변환하여 주입
    value = bcrypt("jithub12") 
  }
  depends_on = [helm_release.ingress_nginx]
}

# ArgoCD 프로젝트 구성
resource "kubectl_manifest" "argocd_project" {
  depends_on = [helm_release.argocd]
  yaml_body  = file("${path.module}/../../../gitops/argocd/projects/jit-hub-project.yaml")
}

# Spoke(온프레미스 로컬) 클러스터 등록
resource "kubectl_manifest" "onprem_cluster" {
  depends_on = [helm_release.argocd]
  yaml_body  = file("${path.module}/../../../gitops/argocd/clusters/onprem-cluster.yaml")
}
