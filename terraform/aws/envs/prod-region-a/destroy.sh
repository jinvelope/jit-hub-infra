#!/bin/bash

set -e

ROOT_DIR=$(pwd)
ONPREM_CONTEXT="kubernetes-admin@kubernetes"
EKS_CONTEXT="eks-a"

echo "================================="
echo " Terraform Destroy Start"
echo "================================="

# Karpenter 노드와 ELB는 Terraform state에 없어 VPC 삭제를 막으므로 먼저 제거
# ScaledObject/NodePool은 KEDA/Karpenter보다 먼저 지워야 finalizer로 인한 timeout이 없음
cleanup_k8s () {
  echo ""
  echo "================================="
  echo " Cleaning up non-Terraform resources"
  echo "================================="

  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "cluster not reachable, skip"
    return 0
  fi

  # ArgoCD가 selfHeal로 리소스를 재생성하면 삭제가 무한 반복되므로
  # 온프레미스의 eks-a Application을 먼저 제거
  echo "--- ArgoCD Application 제거 (selfHeal 차단) ---"
  kubectl --context="${ONPREM_CONTEXT}" delete application \
    -n argocd -l argocd.argoproj.io/instance --ignore-not-found 2>/dev/null || true
  kubectl --context="${ONPREM_CONTEXT}" get application -n argocd -o name 2>/dev/null \
    | grep "eks-a" \
    | xargs -r kubectl --context="${ONPREM_CONTEXT}" delete -n argocd --ignore-not-found || true
  sleep 10

  echo "--- ScaledObject 제거 ---"
  kubectl delete scaledobject --all -A --ignore-not-found --timeout=60s || true

  # finalizer가 남아 삭제되지 않는 경우 강제 제거
  kubectl get scaledobject -A --no-headers 2>/dev/null \
    | awk '{print $1, $2}' \
    | while read ns name; do
        [ -z "$name" ] && continue
        echo "  finalizer 강제 제거: $ns/$name"
        kubectl patch scaledobject "$name" -n "$ns" \
          -p '{"metadata":{"finalizers":null}}' --type=merge || true
      done

  echo "--- Karpenter 리소스 제거 ---"
  kubectl delete nodepool --all --ignore-not-found --timeout=120s || true
  kubectl delete ec2nodeclass --all --ignore-not-found --timeout=120s || true

  kubectl get nodepool --no-headers 2>/dev/null | awk '{print $1}' \
    | while read name; do
        [ -z "$name" ] && continue
        kubectl patch nodepool "$name" -p '{"metadata":{"finalizers":null}}' --type=merge || true
      done

  echo "--- LoadBalancer Service 제거 (ELB 정리) ---"
  kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    | while read ns name; do
        [ -z "$name" ] && continue
        kubectl delete svc "$name" -n "$ns" --ignore-not-found || true
      done

  echo "--- AWS 리소스 해제 대기 (120초) ---"
  sleep 120
}

destroy_layer () {
  LAYER=$1

  echo ""
  echo "================================="
  echo " Destroy ${LAYER}"
  echo "================================="

  cd "${ROOT_DIR}/${LAYER}"

  terraform init

  terraform destroy -auto-approve
}

# cleanup 대상이 반드시 Primary 클러스터를 가리키도록 context를 고정
kubectl config use-context "${EKS_CONTEXT}"

# ApplicationSet이 cleanup한 EKS-A 리소스를 다시 생성하지 않도록
# Primary 클러스터를 generator 선택 대상에서 먼저 제외
kubectl \
  --context "${ONPREM_CONTEXT}" \
  -n argocd \
  label secret cluster-eks-a environment- \
  --overwrite || true

cleanup_k8s

destroy_layer "05-eks-autoscaling"
destroy_layer "04-eks-workloads"
destroy_layer "03-platform"
destroy_layer "02-eks"
destroy_layer "01-network"

# =========================================================
# 잔여 ENI 정리 (보안그룹 삭제를 막는 원인)
# =========================================================
echo ""
echo "================================="
echo " Checking leftover ENIs"
echo "================================="

REGION="${AWS_REGION:-ap-northeast-2}"
LEFT_ENI=$(aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=status,Values=available" \
  --query 'NetworkInterfaces[?starts_with(Description, `aws-K8S`)].NetworkInterfaceId' \
  --output text 2>/dev/null || true)

if [ -n "$LEFT_ENI" ]; then
  echo "잔여 ENI 발견: $LEFT_ENI"
  for eni in $LEFT_ENI; do
    aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" || true
  done
else
  echo "잔여 ENI 없음"
fi

# =========================================================
# 로컬 kubeconfig 컨텍스트 정리 및 온프레미스 복귀
# =========================================================
echo ""
echo "================================="
echo " Cleaning up local kubeconfig contexts"
echo "================================="

kubectl config use-context "${ONPREM_CONTEXT}"

kubectl config delete-context eks-a || true

# # hello-eks의 ARN 형식으로 생성된 잔여 컨텍스트도 함께 삭제
# for ctx in $(kubectl config get-contexts -o name | grep "cluster/hello-eks"); do
#   kubectl config delete-context "$ctx" || true
# done

echo ""
echo "================================="
echo " Terraform Destroy Complete"
echo "================================="
