#!/usr/bin/env bash

# =========================================================
# 공통 설정 및 함수
#
# 이 파일은 직접 실행하지 않는다.
# 01, 02, 03 스크립트에서 source 해서 사용한다.
# =========================================================

set -Eeuo pipefail


# =========================================================
# 경로
# =========================================================

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  pwd
)"

PROJECT_ROOT="$(
  cd "${SCRIPT_DIR}/.."
  pwd
)"

LOG_DIR="${SCRIPT_DIR}/logs"
HISTORY_FILE="${LOG_DIR}/failover-history.csv"
HISTORY_LOCK_FILE="${LOG_DIR}/failover-history.lock"
APP_READY_RETRY="${APP_READY_RETRY:-60}"
APP_READY_INTERVAL="${APP_READY_INTERVAL:-5}"

mkdir -p "$LOG_DIR"


# EKS-A
CTX_A="${CTX_A:-eks-a}"

# 온프레미스
CTX_ONPREM="${CTX_ONPREM:-kubernetes-admin@kubernetes}"

# EKS-B
CTX_B="${CTX_B:-eks-b}"


# =========================================================
# Cloudflared
# =========================================================
CLOUDFLARED_NAMESPACE="${CLOUDFLARED_NAMESPACE:-cloudflared}"
CLOUDFLARED_DEPLOYMENT="${CLOUDFLARED_DEPLOYMENT:-cloudflared}"


# =========================================================
# 애플리케이션
# =========================================================
APP_NAMESPACE="${APP_NAMESPACE:-jit-hub}"

# 실제 Service 이름
APP_SERVICE="${APP_SERVICE:-gateway-service}"

# 실제 Service 포트
APP_PORT="${APP_PORT:-80}"

APP_HEALTH_PATH="${APP_HEALTH_PATH:-/health}"

# GitOps에서 생성되는 앱 Pod 라벨
APP_LABEL_SELECTOR="${APP_LABEL_SELECTOR:-app=gateway}"

# 반드시 실제 외부 도메인으로 변경
EXTERNAL_HEALTH_URL="${EXTERNAL_HEALTH_URL:-https://ccmall.shop/health}"


# =========================================================
# Argo CD / ApplicationSet
# =========================================================
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

# Terraform에서 생성하는 EKS-B 등록용 Secret 이름
ARGOCD_CLUSTER_SECRET_NAME="${ARGOCD_CLUSTER_SECRET_NAME:-cluster-eks-b}"

# Application의 spec.destination.name 값
# ApplicationSet 템플릿에서 name 또는 nameNormalized를 쓴 경우
# 실제 값에 맞춰 변경한다.
ARGOCD_DESTINATION_NAME="${ARGOCD_DESTINATION_NAME:-eks-b}"

INFRA_APPLICATIONSET_FILE="${INFRA_APPLICATIONSET_FILE:-${PROJECT_ROOT}/gitops/argocd/applicationsets/infra-applicationset.yaml}"

APP_APPLICATIONSET_FILE="${APP_APPLICATIONSET_FILE:-${PROJECT_ROOT}/gitops/argocd/applicationsets/app-applicationset.yaml}"


# =========================================================
# Timeout / Retry
# =========================================================

ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
NODE_READY_TIMEOUT="${NODE_READY_TIMEOUT:-900s}"
APP_READY_TIMEOUT="${APP_READY_TIMEOUT:-900s}"

HEALTH_RETRY="${HEALTH_RETRY:-30}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-10}"

ARGOCD_RETRY="${ARGOCD_RETRY:-180}"
ARGOCD_INTERVAL="${ARGOCD_INTERVAL:-5}"


# =========================================================
# 실행 로그 초기화
# =========================================================

SCENARIO="${SCENARIO:-unknown}"
RUN_ID="${RUN_ID:-$(date '+%Y%m%d-%H%M%S')}"

LOG_FILE="${LOG_DIR}/${SCENARIO}-${RUN_ID}.log"

SCRIPT_STARTED_AT="$(date +%s)"

if [[ ! -f "$HISTORY_FILE" ]]; then
  printf '%s\n' \
    'timestamp,run_id,scenario,step,target,status,duration_sec,message' \
    > "$HISTORY_FILE"
fi


# =========================================================
# 로그 함수
# =========================================================

timestamp() {
  date --iso-8601=seconds
}

log() {
  local level="$1"
  shift

  printf '%s [%s] [%s] [%s] %s\n' \
    "$(timestamp)" \
    "$RUN_ID" \
    "$SCENARIO" \
    "$level" \
    "$*" | tee -a "$LOG_FILE"
}

csv_escape() {
  local value="$1"

  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

record_step() {
  local step="$1"
  local target="$2"
  local status="$3"
  local duration="$4"
  local message="$5"

  local record

  record="$(
    {
      printf '%s,%s,%s,%s,%s,%s,%s,' \
        "$(timestamp)" \
        "$RUN_ID" \
        "$SCENARIO" \
        "$step" \
        "$target" \
        "$status" \
        "$duration"

      csv_escape "$message"
    }
  )"

  # 01과 02가 동시에 CSV에 쓰므로 flock으로 충돌 방지
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 9
      printf '%s\n' "$record" >> "$HISTORY_FILE"
    ) 9>>"$HISTORY_LOCK_FILE"
  else
    printf '%s\n' "$record" >> "$HISTORY_FILE"
  fi
}

finish_script() {
  local status="$1"
  local message="${2:-completed}"

  local ended_at
  local duration

  ended_at="$(date +%s)"
  duration=$((ended_at - SCRIPT_STARTED_AT))

  log INFO \
    "SCRIPT_END status=${status} duration=${duration}s message=${message}"

  record_step \
    "total" \
    "$SCENARIO" \
    "$status" \
    "$duration" \
    "$message"
}

run_step() {
  local step="$1"
  local target="$2"
  shift 2

  local started_at
  local ended_at
  local duration
  local exit_code

  started_at="$(date +%s)"

  log INFO \
    "STEP_START step=${step} target=${target}"

  set +e

  "$@" 2>&1 | tee -a "$LOG_FILE"
  exit_code=${PIPESTATUS[0]}

  set -e

  ended_at="$(date +%s)"
  duration=$((ended_at - started_at))

  if [[ "$exit_code" -eq 0 ]]; then
    log INFO \
      "STEP_SUCCESS step=${step} target=${target} duration=${duration}s"

    record_step \
      "$step" \
      "$target" \
      "SUCCESS" \
      "$duration" \
      "completed"

    return 0
  fi

  log ERROR \
    "STEP_FAILED step=${step} target=${target} duration=${duration}s exit_code=${exit_code}"

  record_step \
    "$step" \
    "$target" \
    "FAILED" \
    "$duration" \
    "exit_code=${exit_code}"

  return "$exit_code"
}


# =========================================================
# 필수 명령어 확인
# =========================================================

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    log ERROR \
      "필수 명령어가 설치되어 있지 않습니다: ${command_name}"

    return 1
  fi
}


# =========================================================
# Kubernetes 기본 확인
# =========================================================

check_context() {
  local context="$1"

  if ! kubectl config get-contexts "$context" \
    >/dev/null 2>&1; then

    log ERROR \
      "Kubernetes context가 존재하지 않습니다: ${context}"

    return 1
  fi
}

check_cluster() {
  local context="$1"

  log INFO \
    "Kubernetes API 확인 context=${context}"

  kubectl \
    --context "$context" \
    get --raw='/readyz' \
    >/dev/null
}

context_is_available() {
  local context="$1"

  check_context "$context" >/dev/null 2>&1 \
    && check_cluster "$context" >/dev/null 2>&1
}


# =========================================================
# Cloudflared Replica
# =========================================================

get_cloudflared_replicas() {
  local context="$1"

  local replicas

  replicas="$(
    kubectl \
      --context "$context" \
      -n "$CLOUDFLARED_NAMESPACE" \
      get deployment "$CLOUDFLARED_DEPLOYMENT" \
      -o jsonpath='{.spec.replicas}' \
      2>/dev/null || true
  )"

  printf '%s\n' "${replicas:-0}"
}

wait_for_cloudflared_replicas() {
  local context="$1"
  local expected="$2"

  local attempt
  local desired
  local ready

  for ((attempt = 1; attempt <= HEALTH_RETRY; attempt++)); do
    desired="$(
      kubectl \
        --context "$context" \
        -n "$CLOUDFLARED_NAMESPACE" \
        get deployment "$CLOUDFLARED_DEPLOYMENT" \
        -o jsonpath='{.status.replicas}' \
        2>/dev/null || true
    )"

    ready="$(
      kubectl \
        --context "$context" \
        -n "$CLOUDFLARED_NAMESPACE" \
        get deployment "$CLOUDFLARED_DEPLOYMENT" \
        -o jsonpath='{.status.readyReplicas}' \
        2>/dev/null || true
    )"

    desired="${desired:-0}"
    ready="${ready:-0}"

    log INFO \
      "cloudflared 대기 context=${context} desired=${desired} ready=${ready} expected=${expected} attempt=${attempt}/${HEALTH_RETRY}"

    if [[ "$expected" -eq 0 ]]; then
      if [[ "$desired" -eq 0 ]] && [[ "$ready" -eq 0 ]]; then
        return 0
      fi
    else
      if [[ "$ready" -ge "$expected" ]]; then
        return 0
      fi
    fi

    sleep "$HEALTH_INTERVAL"
  done

  log ERROR \
    "cloudflared replica 확인 실패 context=${context} expected=${expected}"

  return 1
}

scale_cloudflared() {
  local context="$1"
  local replicas="$2"

  log INFO \
    "cloudflared scale context=${context} replicas=${replicas}"

  kubectl \
    --context "$context" \
    -n "$CLOUDFLARED_NAMESPACE" \
    scale deployment "$CLOUDFLARED_DEPLOYMENT" \
    --replicas="$replicas"

  if [[ "$replicas" -gt 0 ]]; then
    kubectl \
      --context "$context" \
      -n "$CLOUDFLARED_NAMESPACE" \
      rollout status \
      deployment/"$CLOUDFLARED_DEPLOYMENT" \
      --timeout="$ROLLOUT_TIMEOUT"
  fi

  wait_for_cloudflared_replicas \
    "$context" \
    "$replicas"
}


# =========================================================
# Node / App 상태 확인
# =========================================================

wait_for_nodes() {
  local context="$1"

  kubectl \
    --context "$context" \
    wait \
    --for=condition=Ready \
    node \
    --all \
    --timeout="$NODE_READY_TIMEOUT"
}

wait_for_app_pods() {
  local context="$1"
  local attempt
  local pod_count
  local ready_count

  for ((attempt=1; attempt<=APP_READY_RETRY; attempt++)); do
    pod_count="$(
      kubectl \
        --context "$context" \
        -n "$APP_NAMESPACE" \
        get pods \
        -l "$APP_LABEL_SELECTOR" \
        --no-headers \
        2>/dev/null \
        | wc -l
    )"

    ready_count="$(
      kubectl \
        --context "$context" \
        -n "$APP_NAMESPACE" \
        get pods \
        -l "$APP_LABEL_SELECTOR" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' \
        2>/dev/null \
        | grep -c '^true$' \
        || true
    )"

    log INFO \
      "애플리케이션 Pod 상태 total=${pod_count} ready=${ready_count} attempt=${attempt}/${APP_READY_RETRY}"

    if [[ "$pod_count" -gt 0 && "$ready_count" -eq "$pod_count" ]]; then
      log INFO \
        "애플리케이션 Pod Ready 완료 selector=${APP_LABEL_SELECTOR}"

      return 0
    fi

    sleep "$APP_READY_INTERVAL"
  done

  log ERROR \
    "애플리케이션 Pod Ready timeout selector=${APP_LABEL_SELECTOR}"

  kubectl \
    --context "$context" \
    -n "$APP_NAMESPACE" \
    get pods \
    -l "$APP_LABEL_SELECTOR" \
    -o wide \
    || true

  return 1
}

# =========================================================
# Health Check
# =========================================================

check_internal_health() {
  local context="$1"

  local pod_name

  pod_name="healthcheck-${RANDOM}-$(date +%s)"

  log INFO \
    "내부 헬스체크 context=${context} service=${APP_SERVICE}"

  kubectl \
    --context "$context" \
    -n "$APP_NAMESPACE" \
    run "$pod_name" \
    --rm \
    --attach \
    --restart=Never \
    --pod-running-timeout="$APP_READY_TIMEOUT" \
    --image=curlimages/curl:8.10.1 \
    --command -- \
    curl \
      --silent \
      --show-error \
      --fail \
      --retry "$HEALTH_RETRY" \
      --retry-delay "$HEALTH_INTERVAL" \
      --retry-all-errors \
      --max-time "$HEALTH_TIMEOUT" \
      "http://${APP_SERVICE}:${APP_PORT}${APP_HEALTH_PATH}"
}

check_external_health() {
  local attempt
  local http_code

  for ((attempt = 1; attempt <= HEALTH_RETRY; attempt++)); do
    http_code="$(
      curl \
        --silent \
        --output /dev/null \
        --write-out '%{http_code}' \
        --max-time "$HEALTH_TIMEOUT" \
        "$EXTERNAL_HEALTH_URL" \
        || true
    )"

    if [[ "$http_code" == "200" ]]; then
      log INFO \
        "외부 헬스체크 성공 url=${EXTERNAL_HEALTH_URL} code=${http_code}"

      return 0
    fi

    log WARN \
      "외부 헬스체크 대기 url=${EXTERNAL_HEALTH_URL} code=${http_code:-000} attempt=${attempt}/${HEALTH_RETRY}"

    sleep "$HEALTH_INTERVAL"
  done

  log ERROR \
    "외부 헬스체크 실패 url=${EXTERNAL_HEALTH_URL}"

  return 1
}


# =========================================================
# Argo CD Cluster Secret
# =========================================================

wait_for_argocd_cluster_secret() {
  local context="$1"

  local attempt

  for ((attempt = 1; attempt <= ARGOCD_RETRY; attempt++)); do
    if kubectl \
      --context "$context" \
      -n "$ARGOCD_NAMESPACE" \
      get secret "$ARGOCD_CLUSTER_SECRET_NAME" \
      >/dev/null 2>&1; then

      log INFO \
        "Argo CD Cluster Secret 확인 name=${ARGOCD_CLUSTER_SECRET_NAME}"

      return 0
    fi

    log INFO \
      "Argo CD Cluster Secret 대기 name=${ARGOCD_CLUSTER_SECRET_NAME} attempt=${attempt}/${ARGOCD_RETRY}"

    sleep "$ARGOCD_INTERVAL"
  done

  log ERROR \
    "Argo CD Cluster Secret 생성 확인 실패 name=${ARGOCD_CLUSTER_SECRET_NAME}"

  return 1
}


# =========================================================
# ApplicationSet
# =========================================================

apply_applicationsets() {
  local context="$1"

  local file

  for file in \
    "$INFRA_APPLICATIONSET_FILE" \
    "$APP_APPLICATIONSET_FILE"
  do
    if [[ ! -f "$file" ]]; then
      log ERROR \
        "ApplicationSet 파일이 없습니다: ${file}"

      return 1
    fi

    log INFO \
      "ApplicationSet 적용 context=${context} file=${file}"

    kubectl \
      --context "$context" \
      apply \
      -f "$file"
  done
}

capture_argocd_state() {
  local context="$1"
  local label="$2"

  {
    echo
    echo "===== Argo CD State: ${label} ====="

    echo
    echo "--- Cluster Secrets ---"

    kubectl \
      --context "$context" \
      -n "$ARGOCD_NAMESPACE" \
      get secret \
      -l argocd.argoproj.io/secret-type=cluster \
      --show-labels \
      2>&1 || true

    echo
    echo "--- ApplicationSets ---"

    kubectl \
      --context "$context" \
      -n "$ARGOCD_NAMESPACE" \
      get applicationsets.argoproj.io \
      2>&1 || true

    echo
    echo "--- Applications ---"

    kubectl \
      --context "$context" \
      -n "$ARGOCD_NAMESPACE" \
      get applications.argoproj.io \
      -o custom-columns='NAME:.metadata.name,DESTINATION:.spec.destination.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
      2>&1 || true

    echo
  } | tee -a "$LOG_FILE"
}

wait_for_eks_b_applications() {
  local context="$1"

  local attempt
  local app_lines
  local result
  local total
  local not_ready

  for ((attempt = 1; attempt <= ARGOCD_RETRY; attempt++)); do
    app_lines="$(
      kubectl \
        --context "$context" \
        -n "$ARGOCD_NAMESPACE" \
        get applications.argoproj.io \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.destination.server}{"|"}{.status.sync.status}{"|"}{.status.health.status}{"\n"}{end}' \
        2>/dev/null || true
    )"

    result="$(
      printf '%s\n' "$app_lines" |
      awk -F'|' '
        $1 == "eks-b-jit-hub-app" ||
        $1 == "eks-b-postgres-gateway" ||
        $1 == "eks-b-monitoring-stack" {
          total++

          if ($3 != "Synced" || $4 != "Healthy") {
            not_ready++
          }
        }

        END {
          printf "%d %d", total + 0, not_ready + 0
        }
      '
    )"

    read -r total not_ready <<< "$result"

    total="${total:-0}"
    not_ready="${not_ready:-0}"

    log INFO \
      "EKS-B GitOps 상태 total=${total} not_ready=${not_ready} attempt=${attempt}/${ARGOCD_RETRY}"

    printf '%s\n' "$app_lines" |
      awk -F'|' '
        $1 == "eks-b-jit-hub-app" ||
        $1 == "eks-b-postgres-gateway" ||
        $1 == "eks-b-monitoring-stack"
      ' |
      tee -a "$LOG_FILE" || true

    if [[ "$total" -eq 3 ]] \
      && [[ "$not_ready" -eq 0 ]]; then

      log INFO \
        "EKS-B 필수 Argo CD Application Synced/Healthy"

      return 0
    fi

    sleep "$ARGOCD_INTERVAL"
  done

  log ERROR \
    "EKS-B Argo CD Application 배포 완료 대기 시간 초과"

  return 1
}

# =========================================================
# 상태 수집
# =========================================================

capture_cluster_state() {
  local context="$1"
  local label="$2"

  log INFO \
    "클러스터 상태 수집 context=${context} label=${label}"

  {
    echo
    echo "===== ${label}: Nodes ====="

    kubectl \
      --context "$context" \
      get nodes \
      -o wide \
      2>&1 || true

    echo
    echo "===== ${label}: Cloudflared ====="

    kubectl \
      --context "$context" \
      -n "$CLOUDFLARED_NAMESPACE" \
      get deployment,pod \
      -o wide \
      2>&1 || true

    echo
    echo "===== ${label}: Application ====="

    kubectl \
      --context "$context" \
      -n "$APP_NAMESPACE" \
      get deployment,pod,service,ingress \
      -o wide \
      2>&1 || true

    echo
  } | tee -a "$LOG_FILE"
}