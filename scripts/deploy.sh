#!/bin/bash
set -e

echo "Starting zero-downtime deployment demo"

# ── 1. Apply manifests ─────────────────────────────────────────────────────────
echo "Applying Kubernetes manifests..."
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml

# ── 2. Wait for v1 to be ready ────────────────────────────────────────────────
echo "Waiting for v1 to be ready..."
kubectl rollout status deployment/auth-service

SERVICE_URL="http://$(minikube ip):30080"
echo "v1 is live at $SERVICE_URL"

# ── 3. Start traffic loop in background ───────────────────────────────────────
echo "Starting traffic loop..."
FAILED=0
SUCCESS=0

while true; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" $SERVICE_URL/health)
  if [ "$STATUS" == "200" ]; then
    SUCCESS=$((SUCCESS + 1))
    echo "[$SUCCESS ok / $FAILED failed] GET /health → $STATUS"
  else
    FAILED=$((FAILED + 1))
    echo "[$SUCCESS ok / $FAILED failed] GET /health → $STATUS"
  fi
  sleep 0.5
done &

TRAFFIC_PID=$!

# ── 4. Deploy v2 ──────────────────────────────────────────────────────────────
sleep 3
echo "Deploying v2..."
kubectl set image deployment/auth-service auth-service=auth-service:v2
kubectl rollout status deployment/auth-service

echo "=========================================="
echo "Deployment complete"
echo "To rollback: kubectl rollout undo deployment/auth-service"

# ── 5. Simulate bad deployment ────────────────────────────────────────────────
echo "Simulating bad v2 (BAD_MODE=true)..."
kubectl set env deployment/auth-service BAD_MODE=true

echo "Waiting 30 seconds for Prometheus to detect the issue..."
sleep 30

echo "Check Prometheus alerts at http://$(minikube ip):9090/alerts"

# ── 6. Rollback ───────────────────────────────────────────────────────────────
echo "Rolling back..."
kubectl set env deployment/auth-service BAD_MODE=false
kubectl rollout status deployment/auth-service

# ── 7. Stop traffic loop ──────────────────────────────────────────────────────
sleep 3
kill $TRAFFIC_PID

echo ""
echo "=========================================="
echo "Successful requests : $SUCCESS"
echo "Failed requests     : $FAILED"
echo "Rollback complete — service restored"