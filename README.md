# Zero-Downtime Deployment — Authorization Service

## Scenario
Deploy a new rate-limiting module to FlowMart's authorization service before Black Friday (45,000 transactions/hour) with zero downtime and rollback capability under 2 minutes.

---

## Architecture Thinking

When I first analyzed this scenario, three problems stood out:

**1. Variable traffic — 15x spike on Black Friday**
Normal daily traffic is not the same as Black Friday. The system needs to scale horizontally based on demand, not just run a fixed number of instances. This is why the HPA is configured with a wide range (3-15 replicas) and a conservative CPU threshold (60%) — to react before the service saturates, not after.

**2. Zero downtime deployments**
The last production deployment took the service offline for 4 minutes causing $37,000 in lost GMV. That's a process problem, not just a technical one. Kubernetes RollingUpdate with `maxUnavailable: 0` solves this at the orchestration level — no pod is removed until its replacement is healthy and serving traffic.

**3. Single region — eu-west-1 (Ireland) for East Africa clients**
FlowMart operates in Kenya, Uganda, and Tanzania. Routing all traffic through Ireland means high latency on every transaction. The right production solution is a second region in **af-south-1 (Cape Town)** with Route 53 latency-based routing. This is documented as a production consideration.

**Why not Event-Driven Architecture?**
An authorization service is synchronous by nature, the client needs to know immediately if a transaction was approved or rejected. EDA works well for async workloads like notifications, reporting, or audit logs. Adding a message broker (Kafka, SQS) here would introduce latency and complexity that directly conflicts with the real-time authorization requirement. Containers + Kubernetes is the right fit: the service is stateless, scales horizontally without friction, and Kubernetes already solves rolling updates, health checks, self-healing, and autoscaling out of the box.

**Why not Fargate?**
Fargate makes sense for stable predictable workloads, small teams that don't want to manage nodes, or batch jobs where cold start doesn't matter. For Black Friday traffic spikes, EC2 node groups give more control.

---

## Stack
- **Runtime**: Python FastAPI + uvicorn
- **Orchestration**: Kubernetes (minikube for local demo, EKS for production)
- **Observability**: Prometheus + prometheus-fastapi-instrumentator
- **CI/CD**: GitHub Actions

---

## Key Decisions

| Decision | Choice | Why |
|---|---|---|
| Deployment strategy | RollingUpdate | Zero downtime — new pods are ready before old ones are removed |
| `maxUnavailable` | 0 | No pod goes down without a healthy replacement |
| `maxSurge` | 1 | One extra pod during rollout — enough redundancy without over-provisioning |
| `averageUtilization` | 60% | Leaves headroom before saturation — critical for 15x Black Friday spike |
| `preStop: sleep 5` | 5s grace period | Prevents in-flight request failures during graceful shutdown |
| Service type | NodePort (minikube) | LoadBalancer requires cloud provider — NodePort works locally |
| Secrets | `kubectl create secret` from env vars | Secrets never appear in the repository or container image |
| Observability | Prometheus (no Grafana) | Sufficient for demo — Grafana + CloudWatch in production |

---

## Production Considerations

### Eliminating Single Points of Failure

| Level | Solution | Recovery Time |
|---|---|---|
| Pod failure | Kubernetes self-healing (min 3 replicas) | Seconds |
| Node failure | Cluster Autoscaler provisions replacement | Minutes |
| AZ failure | Multi-AZ node groups across eu-west-1a/b/c | Seconds |
| Region failure | Route 53 failover to af-south-1 | Seconds |

### Full Production Stack
- **Terraform Structure**
Infrastructure as code using Terraform modules — reproducible and auditable across environments:cluster, node groups, VPC, IAM roles. Reproducible across environments (staging, production) and auditable for compliance. 

terraform/
├── modules/
│   ├── eks/        # Cluster, node groups, Cluster Autoscaler
│   ├── vpc/        # Subnets, AZs, routing, NAT
│   ├── iam/        # Roles, policies, OIDC for GitHub Actions
│   └── secrets/    # AWS Secrets Manager, CSI Driver config
└── environments/
    ├── dev/
    │   ├── main.tf
    │   └── backend.tf    # S3: terraform-state-dev
    ├── staging/
    │   ├── main.tf
    │   └── backend.tf    # S3: terraform-state-staging
    └── production/
        ├── main.tf
        └── backend.tf    # S3: terraform-state-prod


- **Multi-region** eu-west-1 (Ireland) + af-south-1 (Cape Town) for East Africa latency reduction
- **Route 53** latency-based routing + health check failover between regions
- **ALB (Application Load Balancer)** distributes traffic across pods and AZs
- **RDS Multi-AZ** with read replicas — automatic failover if primary goes down
- **CloudWatch Container Insights** for metrics and alerting in EKS — integrates natively with AWS infrastructure and supports CloudWatch Alarms
- **AWS Secrets Manager + Secrets Store CSI Driver** for secret rotation without redeployment
---

## Project Structure

```
.
├── main.py                          # FastAPI authorization service
├── Dockerfile
├── requirements.txt
├── .env.example
├── .gitignore
├── k8s/
│   ├── deployment.yaml              # RollingUpdate strategy + probes
│   ├── service.yaml                 # NodePort (minikube)
│   ├── hpa.yaml                     # Horizontal Pod Autoscaler (3-15 replicas)
│   └── prometheus.yaml              # Prometheus deployment + alert rules
├── scripts/
│   ├── create-secrets.sh            # Creates K8s secret from env vars
│   └── deploy.sh                    # Full demo: v1 → v2 → bad deploy → rollback
└── .github/
    └── workflows/
        └── ci-cd.yml                # Build → Gitleaks → CodeQL → Trivy → Deploy
```

---

## Prerequisites
- Docker
- minikube
- kubectl

---

## Running the Demo

### 1. Start minikube
```bash
minikube start
eval $(minikube docker-env)
```

### 2. Build the image
```bash
docker build -t auth-service:v1 .
```

### 3. Create secrets
```bash
cp .env.example .env
# Edit .env with your values
bash scripts/create-secrets.sh
```

### 4. Apply manifests
```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml
kubectl apply -f k8s/prometheus.yaml
```

### 5. Get service URLs
```bash
minikube service auth-service --url   # auth service
minikube service prometheus --url     # prometheus UI
```

### 6. Run the full demo
```bash
bash scripts/deploy.sh
```

The script will:
1. Deploy v1 and wait for readiness
2. Start a traffic loop
3. Rolling update to v2 — observe zero failed requests
4. Activate `BAD_MODE=true` — simulate bad deployment
5. Rollback — service restored

---

## Secrets Management

### Local / Demo
```bash
kubectl create secret generic auth-service-secrets \
  --from-literal=PAYMENT_API_KEY=$PAYMENT_API_KEY \
  --from-literal=DB_PASSWORD=$DB_PASSWORD
```

### Secret Rotation in Production
In production, secrets are managed by **AWS Secrets Manager** with the **Secrets Store CSI Driver**:

1. Update the secret value in AWS Secrets Manager
2. The CSI Driver detects the change and updates the mounted secret in the pod
3. The application reads the new value on the next request — no redeployment needed

This decouples secret rotation from the deployment lifecycle — critical for payment infrastructure where credentials may need to be rotated immediately after a suspected breach.

---

### CI/CD Pipeline
### Pipeline Steps

Gitleaks — detects hardcoded secrets in the code before anything else runs
CodeQL — static analysis of the source code looking for logic vulnerabilities
Build — builds the Docker image tagged with the commit SHA
Trivy — scans the image for vulnerabilities in dependencies and OS packages
Deploy — only runs if all previous steps passed

Security Gates

If Gitleaks finds a secret → pipeline fails, nothing gets built
If Trivy finds CRITICAL or HIGH vulnerabilities → no deploy
Deploy only triggers on pushes to main, never on pull requests

Trade-offs
GitHub Actions was chosen for being the most recognizable and requiring no additional infrastructure.

---

## Observability

### Endpoints
| Endpoint | Description |
|---|---|
| `GET /health` | Liveness + readiness check |
| `GET /metrics` | Prometheus metrics |
| `POST /authorize` | Mock payment authorization |

### SLO Alert Rules
| Alert | Condition | Severity |
|---|---|---|
| `HighErrorRate` | Error rate > 0.5% over 2 minutes | Critical |
| `HighLatencyP99` | P99 latency > 2s over 2 minutes | Warning |
| `LowThroughput` | < 1 req/sec over 2 minutes | Warning |

### Simulating a Bad Deployment
```bash
kubectl set env deployment/auth-service BAD_MODE=true
# Watch alerts fire in Prometheus UI → Alerts
kubectl set env deployment/auth-service BAD_MODE=false
```

### Rollback
```bash
kubectl rollout undo deployment/auth-service
kubectl rollout status deployment/auth-service
```