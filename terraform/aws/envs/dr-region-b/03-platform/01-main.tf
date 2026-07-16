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

  envs       = "dr"
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

# 온프레미스 Argo CD 클러스터에 EKS-B 클러스터 등록용 Secret 생성 (kubernetes.onprem 프로바이더 별칭 사용)
resource "kubernetes_secret" "eks_b_cluster_secret" {
  provider = kubernetes.onprem
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