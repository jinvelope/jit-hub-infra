# 03-platform/01-main.tf

# ---------------------------------------------------------
# 3. 애플리케이션 계층 (nginx 배포)
# ---------------------------------------------------------
# EKS 위에 테스트용 nginx Deployment Service 생성
# LoadBalancer 타입으로 외부 접속 가능하게 구성
module "nginx" {
  source = "../../../modules/nginx"

  # 의존성 ( EKS 먼저 생성 이후 배포되도록 )
  #depends_on = [module.eks]
}

# ---------------------------------------------------------
# 4. Tailscale 설치
# ---------------------------------------------------------
# EKS 생성 후 로컬(mgmt) kubectl + ansible 실행
# Tailsacle subnet router를 k8s 에 설치
module "tailscale" {
  source = "../../../modules/tailscale"

  #cluster_name = module.eks.cluster_name
  cluster_name = data.terraform_remote_state.eks.outputs.cluster_name
  region       = "ap-northeast-1"
  auth_key     = var.tailscale_auth_key

  envs = "dr"
}

# DaemonSet이 모든 EKS 노드에서 Tailnet 연결과 온프레미스 라우팅을 준비할 때까지
# 기다린다. 준비 전에는 Argo CD에 클러스터를 등록하지 않아 워크로드 선배포를 막는다.
resource "null_resource" "wait_for_tailscale" {
  depends_on = [module.tailscale]

  triggers = {
    cluster      = data.terraform_remote_state.eks.outputs.cluster_name
    manifest_sha = filesha256("${path.root}/../../../../../ansible/aws/manifests/tailscale-deployment-dr.yaml")
  }

  provisioner "local-exec" {
    working_dir = path.root

    command = <<EOT
      set -e

      aws eks update-kubeconfig \
        --region ap-northeast-1 \
        --name ${data.terraform_remote_state.eks.outputs.cluster_name}

      kubectl -n tailscale rollout status daemonset/tailscale-router --timeout=10m

      desired=$(kubectl -n tailscale get daemonset/tailscale-router -o jsonpath='{.status.desiredNumberScheduled}')
      ready=$(kubectl -n tailscale get daemonset/tailscale-router -o jsonpath='{.status.numberReady}')
      test "$desired" -gt 0
      test "$desired" = "$ready"
    EOT
  }
}

# ---------------------------------------------------------
# 5. Ingress-Nginx 설치 (eks-b)
# ---------------------------------------------------------
module "ingress_nginx" {
  source = "../../../../shared/modules/ingress-nginx"

  namespace     = "ingress-nginx"
  service_type  = "LoadBalancer" # eks-a는 클라우드 LB 사용
  replica_count = 2
}

# ---------------------------------------------------------
# 6. Cloudflared Connector 배포 (eks-b, 평시 replicas=0)
#    ⚠ Tunnel은 여기서 만들지 않음 — onprem에서 생성된 것을 재사용
#    ⚠ TEMPORARY — ArgoCD(charts/cloudflared) 완성되면 이 블록 제거
# ---------------------------------------------------------
module "cloudflared_connector" {
  source = "../../../../shared/modules/cloudflare-prod"

  namespace    = "cloudflared"
  secret_name  = "cloudflared-token"
  tunnel_token = data.terraform_remote_state.onprem.outputs.tunnel_token
  replicas     = 0
}

# ---------------------------------------------------------
# Argo CD에 EKS 클러스터 등록 (Bearer Token 기반 선언적 연동)
# ---------------------------------------------------------

# EKS 내부에 Argo CD 관리용 서비스 어카운트(ServiceAccount) 생성 (기본 EKS 프로바이더 사용)
resource "kubernetes_service_account" "argocd_manager" {
  metadata {
    name      = "argocd-manager"
    namespace = "kube-system"
  }
}

# EKS 내 서비스 어카운트에 cluster-admin 관리 권한 바인딩
resource "kubernetes_cluster_role_binding" "argocd_manager_binding" {
  metadata {
    name = "argocd-manager-role-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.argocd_manager.metadata[0].name
    namespace = "kube-system"
  }
}

# EKS 내 서비스 어카운트에 영구 로그인용 토큰 시크릿 연동 (Kubernetes v1.24+ 대응)
resource "kubernetes_secret" "argocd_manager_token" {
  metadata {
    name      = "argocd-manager-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.argocd_manager.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

# jithub_log.log 초기화 DaemonSet이 모든 EKS 노드에 파일 생성을 마칠 때까지 기다린다.
# promtail은 이 클러스터가 Argo CD에 등록된 뒤 charts/monitoring-stack으로 배포되는데,
# 그 시점에 파일이 이미 존재해야 scrapeConfigs(__path__: /var/log/pods/jithub_log.log)가
# 처음부터 정상 tail되고 Not Ready 루프에 빠지지 않는다.
#
# wait_for_tailscale이 이미 update-kubeconfig로 컨텍스트를 맞춰놨으므로
# 여기서는 다시 호출하지 않고 그 결과에 의존만 한다.
resource "null_resource" "wait_for_jithub_log_init" {
  depends_on = [null_resource.wait_for_tailscale]

  triggers = {
    cluster      = data.terraform_remote_state.eks.outputs.cluster_name
    manifest_sha = filesha256("${path.root}/../../../../../utils/jithub-log-init-daemonset.yaml")
  }

  provisioner "local-exec" {
    working_dir = path.root

    command = <<EOT
      set -e

      kubectl apply -f ${path.root}/../../../../../utils/jithub-log-init-daemonset.yaml

      kubectl -n kube-system rollout status daemonset/jithub-log-init --timeout=5m

      desired=$(kubectl -n kube-system get daemonset/jithub-log-init -o jsonpath='{.status.desiredNumberScheduled}')
      ready=$(kubectl -n kube-system get daemonset/jithub-log-init -o jsonpath='{.status.numberReady}')
      test "$desired" -gt 0
      test "$desired" = "$ready"
    EOT
  }
}

# 온프레미스 Argo CD 클러스터에 EKS-b 클러스터 등록용 Secret 생성 (kubernetes.onprem 프로바이더 별칭 사용)
resource "kubernetes_secret" "eks_b_cluster_secret" {
  provider = kubernetes.onprem

  depends_on = [null_resource.wait_for_tailscale, null_resource.wait_for_jithub_log_init]

  metadata {
    name      = "cluster-eks-b"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "environment"                    = "eks-b"
      "cloud-provider"                 = "aws"
      "status"                         = "active"
    }
  }

  data = {
    name   = "eks-b"
    server = data.terraform_remote_state.eks.outputs.cluster_endpoint
    config = jsonencode({
      bearerToken = kubernetes_secret.argocd_manager_token.data["token"]
      tlsClientConfig = {
        insecure = false
        caData   = data.terraform_remote_state.eks.outputs.cluster_certificate_authority_data
      }
    })
  }
}


resource "kubernetes_namespace" "jit_hub" {
  metadata {
    name = "jit-hub"
  }
}

resource "kubernetes_secret" "harbor_pull" {
  metadata {
    name      = "harbor-pull"
    namespace = kubernetes_namespace.jit_hub.metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${var.harbor_registry_server}" = {
          username = var.harbor_robot_user
          password = var.harbor_robot_pull_token
          auth     = base64encode("${var.harbor_robot_user}:${var.harbor_robot_pull_token}")
        }
      }
    })
  }
}

# jithub_log.log 초기화 DaemonSet이 모든 EKS 노드에 파일 생성을 마칠 때까지 기다린다.
# promtail은 이 클러스터가 Argo CD에 등록된 뒤 charts/monitoring-stack으로 배포되는데,
# 그 시점에 파일이 이미 존재해야 scrapeConfigs(__path__: /var/log/pods/jithub_log.log)가
# 처음부터 정상 tail되고 Not Ready 루프에 빠지지 않는다.
#
# wait_for_tailscale이 이미 update-kubeconfig로 컨텍스트를 맞춰놨으므로
# 여기서는 다시 호출하지 않고 그 결과에 의존만 한다.
resource "null_resource" "wait_for_jithub_log_init" {
  depends_on = [null_resource.wait_for_tailscale]

  triggers = {
    cluster      = data.terraform_remote_state.eks.outputs.cluster_name
    manifest_sha = filesha256("${path.root}/../../../../../utils/jithub-log-init-daemonset.yaml")
  }

  provisioner "local-exec" {
    working_dir = path.root

    command = <<EOT
      set -e

      kubectl apply -f ${path.root}/../../../../../utils/jithub-log-init-daemonset.yaml

      kubectl -n kube-system rollout status daemonset/jithub-log-init --timeout=5m

      desired=$(kubectl -n kube-system get daemonset/jithub-log-init -o jsonpath='{.status.desiredNumberScheduled}')
      ready=$(kubectl -n kube-system get daemonset/jithub-log-init -o jsonpath='{.status.numberReady}')
      test "$desired" -gt 0
      test "$desired" = "$ready"
    EOT
  }
}