# shared/modules/cloudflared/connector/main.tf
# cloudflared 접속용 Secret 생성 모듈
# Deployment는 charts/cloudflared(Helm/ArgoCD)가 담당한다 — 이 모듈은 Secret만 만든다.

resource "kubernetes_namespace" "cloudflare" {
  count = var.create_namespace ? 1 : 0
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_secret" "cloudflared_token" {
  metadata {
    name      = var.secret_name
    namespace = var.namespace
  }
  type = "Opaque"
  data = {
    token = var.tunnel_token
  }

  depends_on = [kubernetes_namespace.cloudflare]
}