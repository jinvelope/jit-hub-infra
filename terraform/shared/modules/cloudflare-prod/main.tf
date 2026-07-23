# shared/modules/cloudflared/connector/main.tf
# cloudflared 접속용 Secret 생성 모듈.
# replicas를 넘기지 않으면 Secret만 생성한다 (서비스용 cloudflared — Deployment는
# charts/cloudflared(Helm/ArgoCD)가 담당). replicas를 넘기면 Deployment까지 직접
# 생성한다 (harbor_connector처럼 항상 Terraform이 전담 관리해야 하는 경우).

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

resource "kubernetes_deployment" "cloudflared" {
  count = var.replicas != null ? 1 : 0

  metadata {
    name      = "cloudflared"
    namespace = var.namespace
    labels    = { app = "cloudflared" }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = { app = "cloudflared" }
    }

    template {
      metadata {
        labels = { app = "cloudflared" }
      }

      spec {
        container {
          name  = "cloudflared"
          image = var.cloudflared_image

          args = [
            "tunnel",
            "--no-autoupdate",
            "run",
            "--token",
            "$(TUNNEL_TOKEN)"
          ]

          env {
            name = "TUNNEL_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.cloudflared_token.metadata[0].name
                key  = "token"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_secret.cloudflared_token]
}