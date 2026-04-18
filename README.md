# 05 - CI/CD Pipeline with Jenkins, Docker, and Kubernetes

A production-ready CI/CD pipeline that automates building, scanning, and deploying a Python Flask application to Kubernetes using Jenkins, SonarQube, Trivy, and Slack notifications.

---

## Architecture Overview

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                    CI/CD Pipeline Flow                              │
  └─────────────────────────────────────────────────────────────────────┘

  Developer          GitHub            Jenkins CI          Tools
  ─────────          ──────            ──────────          ─────
      │                │                   │                 │
      │  git push      │                   │                 │
      ├──────────────► │                   │                 │
      │                │   Webhook         │                 │
      │                ├──────────────────►│                 │
      │                │                   │                 │
      │                │                   ├── Checkout ─────┤
      │                │                   │                 │
      │                │                   ├── Install Deps ─┤
      │                │                   │                 │
      │                │                   ├── Unit Tests ───┤
      │                │                   │                 │
      │                │                   ├── SonarQube ────► SonarQube
      │                │                   │   Analysis      │ Quality Gate
      │                │                   │                 │
      │                │                   ├── Docker ───────► Docker
      │                │                   │   Build         │ Image
      │                │                   │                 │
      │                │                   ├── Trivy ────────► Trivy
      │                │                   │   Scan          │ CVE DB
      │                │                   │                 │
      │                │                   ├── Push ─────────► Container
      │                │                   │   Registry      │ Registry
      │                │                   │                 │
      │                │                   ├── kubectl ──────► Kubernetes
      │                │                   │   deploy        │ Cluster
      │                │                   │                 │
      │                │                   └── Slack ────────► Slack
      │                │                       Notify        │ Channel
      │◄───────────────┴───────────────────────┴─────────────┘
      │            Status Notification
```

---

## Prerequisites

| Tool         | Version    | Purpose                          | Install                                    |
|--------------|------------|----------------------------------|--------------------------------------------|
| kubectl      | >= 1.28    | Kubernetes CLI                   | https://kubernetes.io/docs/tasks/tools/    |
| Docker       | >= 24.0    | Container runtime                | https://docs.docker.com/get-docker/        |
| Helm         | >= 3.12    | Kubernetes package manager       | https://helm.sh/docs/intro/install/        |
| Jenkins      | LTS        | CI/CD server                     | Installed via Helm (see Step 1)            |
| SonarQube    | LTS        | Code quality analysis            | Running via Docker Compose                 |
| Trivy        | >= 0.50    | Container vulnerability scanner  | https://aquasecurity.github.io/trivy/      |
| Git          | >= 2.40    | Source control                   | https://git-scm.com/                       |

---

## Step 1: Install Jenkins via Helm

```bash
# Make the install script executable
chmod +x scripts/install-jenkins.sh

# Install Jenkins with default settings (auto-generated admin password)
./scripts/install-jenkins.sh

# Install with custom settings
./scripts/install-jenkins.sh \
  --namespace cicd \
  --release jenkins \
  --admin-pass "MySecurePassword123!" \
  --storage 20Gi

# Verify the installation
kubectl get pods -n cicd -l app.kubernetes.io/name=jenkins
kubectl get svc  -n cicd jenkins

# Access Jenkins (if using port-forward)
kubectl port-forward -n cicd svc/jenkins 8080:8080 &
open http://localhost:8080
```

---

## Step 2: Configure Jenkins

### 2.1 Install Required Plugins

Navigate to **Manage Jenkins → Plugins → Available plugins** and install:

- Kubernetes (for dynamic agents)
- Pipeline: Stage View
- Blue Ocean
- Docker Pipeline
- SonarQube Scanner
- Slack Notification
- JUnit
- Code Coverage
- Credentials Binding
- Git

### 2.2 Add Credentials

Go to **Manage Jenkins → Credentials → System → Global credentials**:

| Credential ID            | Type                   | Description                          |
|--------------------------|------------------------|--------------------------------------|
| `docker-registry-creds`  | Username/Password      | Docker registry username + password  |
| `kubeconfig`             | Secret file            | Kubernetes kubeconfig file           |
| `sonar-token`            | Secret text            | SonarQube authentication token       |
| `slack-token`            | Secret text            | Slack Bot OAuth token                |

### 2.3 Configure Kubernetes Cloud

Go to **Manage Jenkins → Clouds → New Cloud → Kubernetes**:

```
Kubernetes URL:         https://<cluster-api-server>:6443
Kubernetes Namespace:   cicd
Jenkins URL:            http://jenkins.cicd.svc.cluster.local:8080
Jenkins Tunnel:         jenkins.cicd.svc.cluster.local:50000
```

---

## Step 3: Create Pipeline Job

```
1. Click "New Item"
2. Enter job name: "python-devops-app-pipeline"
3. Select "Pipeline" → OK
4. Under "Pipeline":
   - Definition: "Pipeline script from SCM"
   - SCM: Git
   - Repository URL: <your-github-repo-url>
   - Branch: */main
   - Script Path: Jenkinsfile
5. Enable "GitHub hook trigger for GITScm polling"
6. Save
```

---

## Step 4: Configure SonarQube

### 4.1 Start SonarQube (local development)

```bash
# Start all services including SonarQube
docker compose up -d sonarqube sonarqube-db

# Wait for SonarQube to be ready (may take 2-3 minutes)
docker compose logs -f sonarqube | grep "SonarQube is operational"

# Access SonarQube
open http://localhost:9000
# Default credentials: admin / admin (change on first login)
```

### 4.2 Create SonarQube Project and Token

```
1. Login to http://localhost:9000
2. Create Project → Manually
   - Project key: python-devops-app
   - Display name: Python DevOps App
3. Generate token: My Account → Security → Generate Token
   - Name: jenkins-token
   - Type: Global Analysis Token
4. Copy the token — add it to Jenkins credentials as "sonar-token"
```

### 4.3 Configure SonarQube in Jenkins

Go to **Manage Jenkins → Configure System → SonarQube Servers**:

```
Name:        SonarQube
Server URL:  http://sonarqube:9000
Auth token:  sonar-token (select from credentials)
```

---

## Step 5: Trigger Pipeline via Git Push

```bash
# Clone your repository
git clone <your-repo-url>
cd <repo-name>

# Make a code change
echo "# Trigger build $(date)" >> README.md

# Commit and push
git add .
git commit -m "chore: trigger CI/CD pipeline build"
git push origin main

# Jenkins will automatically pick up the push via webhook
# Monitor pipeline: http://localhost:8080/job/python-devops-app-pipeline/
```

### Setting Up GitHub Webhook

```
GitHub Repository → Settings → Webhooks → Add webhook:
  Payload URL:    http://<jenkins-url>/github-webhook/
  Content type:   application/json
  Events:         Just the push event
```

---

## Step 6: Deploy to Kubernetes

The pipeline automatically deploys to Kubernetes on pushes to `main`/`master`/`release/*` branches. For manual deployment:

```bash
# Apply namespace
kubectl apply -f k8s/namespace.yaml

# Set the image tag (replace with actual build number)
export BUILD_NUMBER=42
export DOCKER_REGISTRY=localhost:5000
export APP_NAME=python-devops-app

# Replace placeholder and apply
sed "s|IMAGE_PLACEHOLDER|${DOCKER_REGISTRY}/${APP_NAME}:${BUILD_NUMBER}|g" \
  k8s/deployment.yaml | kubectl apply -f -

kubectl apply -f k8s/service.yaml

# Watch the rollout
kubectl rollout status deployment/python-devops-app -n cicd

# Verify all pods are running
kubectl get pods -n cicd -l app=python-devops-app
```

---

## Testing

### Verify Application Health

```bash
# Port-forward to the application service
kubectl port-forward svc/python-devops-app -n cicd 8080:80 &

# Test health endpoint
curl http://localhost:8080/health

# Test application endpoint
curl http://localhost:8080/
```

### Verify Pipeline Components

```bash
# Check Jenkins is running
curl http://localhost:8080/jenkins/api/json?pretty=true

# Check SonarQube is running
curl http://localhost:9000/api/system/status

# Check local Docker registry
curl http://localhost:5000/v2/_catalog

# List images in registry
curl http://localhost:5000/v2/python-devops-app/tags/list
```

### Run Tests Locally

```bash
# Create virtual environment
python3 -m venv venv && source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
pip install pytest pytest-cov

# Run tests
pytest tests/ -v --cov=app --cov-report=term-missing

# Run linting
flake8 app/ --max-line-length=120

# Run security scan
bandit -r app/ -f text
```

---

## Cleanup

```bash
# Remove Kubernetes resources
kubectl delete namespace cicd

# Uninstall Jenkins Helm release
helm uninstall jenkins -n cicd

# Stop Docker Compose services
docker compose down -v

# Remove Docker images
docker rmi $(docker images 'localhost:5000/python-devops-app' -q) 2>/dev/null || true

# Remove Helm repo
helm repo remove jenkins
```

---

## Files Reference

| File                              | Purpose                                          |
|-----------------------------------|--------------------------------------------------|
| `Jenkinsfile`                     | Declarative Jenkins pipeline definition          |
| `docker-compose.yml`              | Local dev environment (app, Jenkins, SonarQube, Registry) |
| `k8s/namespace.yaml`              | Kubernetes namespace: `cicd`                     |
| `k8s/deployment.yaml`             | Application Deployment with rolling update       |
| `k8s/service.yaml`                | ClusterIP Service + HPA + PDB                    |
| `k8s/jenkins-deployment.yaml`     | Jenkins StatefulSet + RBAC + PVC                 |
| `scripts/install-jenkins.sh`      | Automated Jenkins Helm install script            |
| `.github/workflows/validate.yml`  | GitHub Actions: yaml-lint, kubeval, checkov      |

---

## Troubleshooting

```bash
# Jenkins pod not starting
kubectl describe pod -n cicd -l app.kubernetes.io/name=jenkins
kubectl logs -n cicd -l app.kubernetes.io/name=jenkins --previous

# Pipeline failing at SonarQube stage
# Verify SonarQube is reachable from Jenkins pod
kubectl exec -n cicd -it <jenkins-pod> -- curl http://sonarqube:9000/api/system/status

# Image push failing
# Verify Docker registry credentials
kubectl exec -n cicd -it <jenkins-pod> -- \
  docker login localhost:5000 -u <user> -p <password>

# Deployment stuck in Pending
kubectl describe pod -n cicd -l app=python-devops-app
# Common causes: insufficient resources, PVC not bound, image pull failure

# Check events in namespace
kubectl get events -n cicd --sort-by='.lastTimestamp'
```
