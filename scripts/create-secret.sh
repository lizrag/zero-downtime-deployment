#!/bin/bash
set -e

# Load .env file
if [ ! -f .env ]; then
  echo ".env file not found. Copy .env.example and fill in your values."
  exit 1
fi

export $(grep -v '^#' .env | xargs)

# Validate secrets are set
if [ -z "$PAYMENT_API_KEY" ] || [ -z "$DB_PASSWORD" ]; then
  echo "PAYMENT_API_KEY and DB_PASSWORD must be set in .env"
  exit 1
fi

# Delete existing secret if it exists
kubectl delete secret auth-service-secrets --ignore-not-found

# Create secret from env vars — no YAML, no plaintext in repo
kubectl create secret generic auth-service-secrets \
  --from-literal=PAYMENT_API_KEY=$PAYMENT_API_KEY \
  --from-literal=DB_PASSWORD=$DB_PASSWORD

echo " Secrets created successfully"