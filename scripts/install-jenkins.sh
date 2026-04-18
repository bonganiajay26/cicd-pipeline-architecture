#!/usr/bin/env bash
# =============================================================================
# install-jenkins.sh - Install Jenkins on Kubernetes via Helm
# =============================================================================
# Usage: ./scripts/install-jenkins.sh [OPTIONS]
# Options:
#   --namespace    Kubernetes namespace (default: cicd)
#   --release      Helm release name   (default: jenkins)
#   --version      Jenkins Helm chart version (default: latest)
#   --admin-pass   Jenkins admin password (default: auto-generated)
#   --storage      PVC storage size (default: 10Gi)
#   --dry-run      Print what would be done without executing
# =============================================================================
set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
log_step()    { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  STEP: $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

# ─── Defaults ────────────────────────────────────────────────────────────────
NAMESPACE="cicd"
RELEASE_NAME="jenkins"
CHART_VERSION=""          # empty = latest
ADMIN_PASSWORD=""         # empty = auto-generate
STORAGE_SIZE="10Gi"
STORAGE_CLASS="standard"
SERVICE_TYPE="LoadBalancer"
DRY_RUN=false
HELM_REPO_NAME="jenkins"
HELM_REPO_URL="https://charts.jenkins.io"
WAIT_TIMEOUT="600s"

# ─── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)   NAMESPACE="$2";       shift 2 ;;
    --release)     RELEASE_NAME="$2";    shift 2 ;;
    --version)     CHART_VERSION="$2";   shift 2 ;;
    --admin-pass)  ADMIN_PASSWORD="$2";  shift 2 ;;
    --storage)     STORAGE_SIZE="$2";    shift 2 ;;
    --dry-run)     DRY_RUN=true;         shift   ;;
    *)             log_error "Unknown option: $1"; exit 1 ;;
  esac
done

# Auto-generate admin password if not provided
if [[ -z "$ADMIN_PASSWORD" ]]; then
  ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-20)
  log_warn "Admin password not provided — auto-generated: ${ADMIN_PASSWORD}"
fi

# ─── Prerequisite checks ─────────────────────────────────────────────────────
log_step "Checking prerequisites"

check_command() {
  if ! command -v "$1" &>/dev/null; then
    log_error "Required tool not found: $1. Please install it and retry."
    exit 1
  fi
  log_info "$1 found: $(command -v "$1")"
}

check_command kubectl
check_command helm
check_command curl

# Verify cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
  log_error "Cannot connect to Kubernetes cluster. Check your KUBECONFIG."
  exit 1
fi

CLUSTER_INFO=$(kubectl config current-context)
log_success "Connected to cluster: ${CLUSTER_INFO}"

# ─── Add Jenkins Helm repository ─────────────────────────────────────────────
log_step "Adding Jenkins Helm repository"

if helm repo list | grep -q "^${HELM_REPO_NAME}"; then
  log_info "Helm repo '${HELM_REPO_NAME}' already exists, updating..."
  helm repo update "${HELM_REPO_NAME}"
else
  log_info "Adding Helm repo: ${HELM_REPO_URL}"
  helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}"
  helm repo update
fi

log_success "Helm repo ready: $(helm repo list | grep "${HELM_REPO_NAME}")"

# Show available chart versions
log_info "Available Jenkins chart versions (top 5):"
helm search repo "${HELM_REPO_NAME}/jenkins" --versions | head -6

# ─── Create namespace ────────────────────────────────────────────────────────
log_step "Creating namespace: ${NAMESPACE}"

if $DRY_RUN; then
  log_warn "[DRY-RUN] Would create namespace: ${NAMESPACE}"
else
  kubectl create namespace "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${NAMESPACE}" \
    name="${NAMESPACE}" \
    managed-by=helm \
    --overwrite
  log_success "Namespace '${NAMESPACE}' ready"
fi

# ─── Build Helm values ───────────────────────────────────────────────────────
log_step "Configuring Helm values"

VERSION_FLAG=""
[[ -n "$CHART_VERSION" ]] && VERSION_FLAG="--version ${CHART_VERSION}"

HELM_VALUES=$(cat <<EOF
controller:
  adminPassword: "${ADMIN_PASSWORD}"
  serviceType: ${SERVICE_TYPE}
  installPlugins:
    - kubernetes:latest
    - workflow-aggregator:latest
    - git:latest
    - configuration-as-code:latest
    - blueocean:latest
    - docker-workflow:latest
    - sonar:latest
    - slack:latest
    - junit:latest
    - coverage:latest
    - pipeline-stage-view:latest
    - credentials-binding:latest
    - ssh-credentials:latest
    - build-timeout:latest
    - timestamper:latest
    - ws-cleanup:latest
    - email-ext:latest

  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi

  javaOpts: >-
    -Djenkins.install.runSetupWizard=false
    -Xms512m
    -Xmx2048m
    -XX:+UseG1GC

  containerEnv:
    - name: JAVA_OPTS
      value: "-Djenkins.install.runSetupWizard=false"

  probes:
    startupProbe:
      failureThreshold: 12
      periodSeconds: 10
    livenessProbe:
      initialDelaySeconds: 120
      periodSeconds: 30
    readinessProbe:
      initialDelaySeconds: 60
      periodSeconds: 15

persistence:
  enabled: true
  size: ${STORAGE_SIZE}
  storageClass: "${STORAGE_CLASS}"
  accessMode: ReadWriteOnce

rbac:
  create: true
  readSecrets: true

serviceAccount:
  create: true
  name: jenkins

agent:
  enabled: true
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 512Mi

backup:
  enabled: false
EOF
)

# ─── Install / Upgrade Jenkins ────────────────────────────────────────────────
log_step "Installing Jenkins via Helm"

HELM_CMD="helm upgrade --install ${RELEASE_NAME} ${HELM_REPO_NAME}/jenkins \
  --namespace ${NAMESPACE} \
  --values - \
  ${VERSION_FLAG} \
  --atomic \
  --timeout ${WAIT_TIMEOUT} \
  --create-namespace"

if $DRY_RUN; then
  log_warn "[DRY-RUN] Would execute:"
  log_warn "  ${HELM_CMD}"
  log_warn "With values:"
  echo "$HELM_VALUES"
else
  log_info "Running Helm install (this may take several minutes)..."
  echo "$HELM_VALUES" | eval "$HELM_CMD"
  log_success "Helm install completed"
fi

# ─── Wait for pods to be ready ───────────────────────────────────────────────
log_step "Waiting for Jenkins pods to be ready"

if ! $DRY_RUN; then
  log_info "Waiting up to ${WAIT_TIMEOUT} for deployment rollout..."
  kubectl rollout status statefulset/"${RELEASE_NAME}" \
    --namespace "${NAMESPACE}" \
    --timeout="${WAIT_TIMEOUT}"

  log_info "Current pod status:"
  kubectl get pods --namespace "${NAMESPACE}" -l "app.kubernetes.io/name=jenkins"
  log_success "All Jenkins pods are ready"
fi

# ─── Retrieve access details ──────────────────────────────────────────────────
log_step "Retrieving access information"

if ! $DRY_RUN; then
  # Determine service type and get access URL
  SVC_TYPE=$(kubectl get svc "${RELEASE_NAME}" \
    --namespace "${NAMESPACE}" \
    -o jsonpath='{.spec.type}' 2>/dev/null || echo "Unknown")

  if [[ "$SVC_TYPE" == "LoadBalancer" ]]; then
    log_info "Waiting for LoadBalancer IP (up to 90s)..."
    for i in $(seq 1 18); do
      EXTERNAL_IP=$(kubectl get svc "${RELEASE_NAME}" \
        --namespace "${NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
      EXTERNAL_HOSTNAME=$(kubectl get svc "${RELEASE_NAME}" \
        --namespace "${NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
      [[ -n "$EXTERNAL_IP" || -n "$EXTERNAL_HOSTNAME" ]] && break
      sleep 5
    done
    JENKINS_URL="http://${EXTERNAL_IP:-$EXTERNAL_HOSTNAME}:8080"
  else
    NODE_PORT=$(kubectl get svc "${RELEASE_NAME}" \
      --namespace "${NAMESPACE}" \
      -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "8080")
    JENKINS_URL="http://<NODE-IP>:${NODE_PORT}"
  fi

  # Print access instructions
  cat <<INSTRUCTIONS

$(echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}")
$(echo -e "${GREEN}║           JENKINS INSTALLATION COMPLETE                      ║${NC}")
$(echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}")

$(echo -e "${CYAN}Access Details:${NC}")
  URL:               ${JENKINS_URL}
  Admin Username:    admin
  Admin Password:    ${ADMIN_PASSWORD}

$(echo -e "${CYAN}Quick Commands:${NC}")
  # View all Jenkins resources
  kubectl get all -n ${NAMESPACE} -l app.kubernetes.io/name=jenkins

  # Get Jenkins logs
  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=jenkins --tail=50

  # Port-forward (alternative access)
  kubectl port-forward -n ${NAMESPACE} svc/${RELEASE_NAME} 8080:8080

  # Get admin password from secret
  kubectl get secret -n ${NAMESPACE} ${RELEASE_NAME} \
    -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo

$(echo -e "${CYAN}Next Steps:${NC}")
  1. Open ${JENKINS_URL} in your browser
  2. Login with admin / ${ADMIN_PASSWORD}
  3. Navigate to Manage Jenkins → Plugins to verify plugin installation
  4. Configure credentials: Manage Jenkins → Credentials
     - Docker registry credentials (ID: docker-registry-creds)
     - Kubernetes kubeconfig (ID: kubeconfig)
     - SonarQube token (ID: sonar-token)
     - Slack token (ID: slack-token)
  5. Create a new Pipeline job pointing to your Jenkinsfile
  6. Configure SonarQube server: Manage Jenkins → Configure System → SonarQube

$(echo -e "${YELLOW}IMPORTANT: Save the admin password shown above!${NC}")

INSTRUCTIONS
fi

log_success "Jenkins installation script completed."
