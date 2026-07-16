# 모니터링/ArgoCD 클러스터 등록 작업 기록 (2026-07-16)

`feature/monitoring` 브랜치에서 진행한 두 가지 작업을 기록한다.

## 배경

JIT-Hub는 AWS A리전(eks-a, 액티브) / AWS B리전(eks-b, DR) / 온프레미스(onprem, standby + 매니지먼트 서버) 3개 환경으로 구성된 하이브리드 DR 플랫폼이다. B리전은 평시엔 네트워크 등 기초 인프라만 두고 컴퓨팅은 장애 시에만 JIT 프로비저닝해 비용을 절감하며, 그 프로비저닝 공백을 온프레 standby가 cloudflared replica 전환으로 메운다. 이 판단(장애 감지, 우회 트리거)을 위해 온프레(매니지먼트 서버)가 각 클러스터의 Pod 메트릭을 중앙에서 모니터링해야 한다.

## 작업 1. eks-a/eks-b → onprem remote_write 복구

커밋: `1c619a6` (push 완료)

기존 `feature/monitoring` 브랜치는 로컬 테스트용으로 eks-a의 remote_write를 꺼두고 임시 로컬 Grafana로 대체해둔 상태였다. 조사 결과 아래 3가지가 함께 걸려 있어 원상 복구 + 버그 수정을 진행했다.

1. **잘못된 도메인**: eks-a/eks-b 모두 remote_write/promtail URL이 placeholder(`jit-hub-domain.com`)를 가리키고 있었음 → 실제 프로비저닝된 도메인(`leechs.shop`, `terraform/onprem/01-onprem-platform/00-providers.tf` 기준)으로 수정
2. **수신측 Ingress 미배포**: `k8s/monitoring-ingress.yaml`이 어떤 Application/Helm 차트에도 연결 안 된 고아 파일이었음 → `charts/monitoring-stack/templates/ingest-ingress.yaml`로 재작성, `ingestIngress.enabled` 플래그로 onprem에서만 활성화되도록 함. 기존 고아 파일은 삭제
3. **backend 서비스명 오류**: 그 고아 파일의 backend가 `monitoring-stack-kube-prometheus-stack-prometheus`로 되어 있었으나, 실제 Helm 릴리즈명 기준 서비스명은 63자 제한으로 잘려서 `onprem-monitoring-stack-ku-prometheus` / `onprem-monitoring-stack-loki` — onprem Grafana datasource 설정에서 이미 검증된 값으로 맞춤

부가로 발견한 버그: `charts/monitoring-stack/templates/loki-pv.yaml`/`loki-pvc.yaml`이 eks-a/eks-b 값 파일에 `loki.nfs`가 아예 없어서 `nil pointer evaluating interface {}.enabled` 에러로 차트 렌더링 자체가 실패했음 → `{{- if and .Values.loki.nfs .Values.loki.nfs.enabled }}`로 nil-safe 가드 추가

`helm template`로 onprem/eks-a/eks-b 3개 값 파일 모두 정상 렌더링 확인 완료.

### 여전히 남은 전제조건 (이번 작업 범위 밖)

- cloudflared 배포가 `gitops/argocd/applicationsets/infra-applicationset.yaml`에서 주석 처리되어 있어 실제로 안 뜸
- 온프렘 Cloudflare Tunnel의 실제 terraform apply(`terraform/onprem/01-onprem-platform`, 실 Cloudflare API 토큰 필요) 여부 불명
- 온프렘 ingress-nginx 설치 여부 불명 (같은 terraform에 포함)
- Loki NFS 서버 IP가 아직 placeholder(`192.168.0.0`) — `gitops/values/onprem/monitoring-stack-values.yaml`

## 작업 2. dr-region-b(eks-b) ArgoCD 클러스터 등록 복사-붙여넣기 버그 수정

커밋: 이번 세션에서 작업, 아직 미커밋

`terraform/aws/envs/prod-region-a/03-platform/01-main.tf`에 ArgoCD 클러스터 등록 메커니즘이 이미 완전히 구현되어 있었다 (EKS에 `argocd-manager` ServiceAccount + cluster-admin ClusterRoleBinding + 영구 토큰 생성 → 그 값으로 onprem ArgoCD에 클러스터 Secret 직접 생성). eks-a는 이 흐름대로 `01-network > 02-eks > 03-platform` apply만 하면 자동 등록된다.

문제는 `terraform/aws/envs/dr-region-b/03-platform/01-main.tf`가 이 파일을 그대로 복사해오면서 eks-b용으로 고치지 않았던 것:

- `kubernetes_secret.eks_a_cluster_secret` 리소스의 `metadata.name`(`cluster-eks-a`), `labels.environment`(`eks-a`), `data.name`(`eks-a`)이 그대로 남아있어서, apply 시 onprem ArgoCD의 `cluster-eks-a` Secret을 **b리전 EKS의 endpoint/token으로 덮어쓰는** 심각한 오배선 버그였음 → `eks_b_cluster_secret`/`cluster-eks-b`/`eks-b`로 수정
- `provider kubernetes.onprem`의 `config_context`가 존재하지도 않는 `kubernetes-admin@kubernetes`로 되어 있어 apply가 실패했을 것 → prod-region-a와 동일한 `docker-desktop`(로컬 kubeconfig의 실제 컨텍스트, 이 프로젝트에서 onprem ArgoCD 역할)으로 수정

EKS API 엔드포인트는 `cluster_endpoint_public_access = true`(`terraform/aws/modules/eks/main.tf`)라 퍼블릭 접근 가능하므로, 이 등록 자체엔 Tailscale 연결이 필요 없다.

`terraform init -backend=false` + `terraform validate` 통과 확인, prod-region-a와 diff해서 tailscale on/off(리전별 의도된 차이)를 제외하면 eks-a→eks-b 네이밍만 다른 것을 확인.

### 여전히 남은 것

- 실제 `terraform apply`는 미실행 — AWS에 EKS 클러스터가 없고 로컬 Docker Desktop k8s도 꺼져 있어 지금은 적용 불가능한 상태. 인프라가 준비되면 `./deploy.sh`로 각 리전 적용 후 onprem에서 `kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster`로 `cluster-eks-a`/`cluster-eks-b`가 각자 올바른 클러스터를 가리키는지 확인 필요
- `02-eks`에서 두 리전 모두 EKS 클러스터명이 `hello-eks`로 동일 (ArgoCD 등록 로직 자체엔 영향 없으나 AWS 콘솔/CLI에서 혼동 가능)
