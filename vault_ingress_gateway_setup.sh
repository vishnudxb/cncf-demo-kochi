#!/bin/bash

# Variables
VAULT_ADDR="http://vault.vault.svc:8200" # Replace with your Vault address
VAULT_ROLE="istio-ca"                   # Vault role configured for Kubernetes auth
CERT_TTL="8760h"                        # Certificate validity (1 year)

# Custom hostnames and cluster configurations
CUSTOM_HOSTNAMES=("nginx1.localhost.com" "nginx2.localhost.com")
CLUSTERS=("kind-cluster1" "kind-cluster2")
GATEWAY_NAMESPACES=("istio-system" "istio-system")
NGINX_NAMESPACES=("default" "default")
SECRETS=("nginx1-cert" "nginx2-cert")

# Function: Login to Vault using Kubernetes service account
vault_login() {
  local cluster_context=$1
  local namespace=$2
  echo "Logging in to Vault for cluster context: $cluster_context..."

  # Extract service account token for the Vault role
  SA_TOKEN=$(kubectl --context="$cluster_context" -n "$namespace" get secret \
    $(kubectl --context="$cluster_context" -n "$namespace" get sa default -o jsonpath='{.secrets[0].name}') \
    -o jsonpath='{.data.token}' | base64 --decode)

  # Login to Vault using Kubernetes auth
  VAULT_TOKEN=$(curl -s --request POST --data '{"jwt": "'"$SA_TOKEN"'", "role": "'"$VAULT_ROLE"'"}' \
    "$VAULT_ADDR/v1/auth/kubernetes/login" | jq -r '.auth.client_token')

  if [[ -z "$VAULT_TOKEN" ]]; then
    echo "Error: Failed to authenticate to Vault for cluster: $cluster_context"
    exit 1
  fi

  echo "Successfully authenticated to Vault for cluster: $cluster_context"
}

# Function: Generate certificates using Vault
generate_certificates() {
  local common_name=$1
  echo "Generating certificate for $common_name..."
  CERT_OUTPUT=$(curl -s --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST --data '{"common_name": "'"$common_name"'", "ttl": "'"$CERT_TTL"'"}' \
    "$VAULT_ADDR/v1/pki/issue/istio-ingress")

  if [[ -z "$CERT_OUTPUT" ]]; then
    echo "Error: Failed to generate certificate for $common_name"
    exit 1
  fi

  # Extract the certificate, key, and CA chain
  TLS_CRT=$(echo "$CERT_OUTPUT" | jq -r '.data.certificate')
  TLS_KEY=$(echo "$CERT_OUTPUT" | jq -r '.data.private_key')
  CA_CRT=$(echo "$CERT_OUTPUT" | jq -r '.data.issuing_ca')

  # Save the certificates to files
  echo "$TLS_CRT" > tls.crt
  echo "$TLS_KEY" > tls.key
  echo "$CA_CRT" > ca.crt
}

# Function: Create Kubernetes secrets
create_k8s_secrets() {
  local cluster_context=$1
  local namespace=$2
  local secret_name=$3

  echo "Creating Kubernetes secret ($secret_name) in cluster: $cluster_context, namespace: $namespace..."

  # Create TLS secret
  kubectl --context="$cluster_context" create secret tls "$secret_name" \
    --cert=tls.crt \
    --key=tls.key \
    -n "$namespace" --dry-run=client -o yaml | kubectl apply -f -

  # Create CA secret
  kubectl --context="$cluster_context" create secret generic "$secret_name-ca" \
    --from-file=ca.crt=ca.crt \
    -n "$namespace" --dry-run=client -o yaml | kubectl apply -f -
}

# Main Execution
for i in "${!CLUSTERS[@]}"; do
  CLUSTER_CONTEXT="${CLUSTERS[$i]}"
  CUSTOM_HOSTNAME="${CUSTOM_HOSTNAMES[$i]}"
  GATEWAY_NAMESPACE="${GATEWAY_NAMESPACES[$i]}"
  NGINX_NAMESPACE="${NGINX_NAMESPACES[$i]}"
  SECRET_NAME="${SECRETS[$i]}"

  echo "Processing cluster: $CLUSTER_CONTEXT with hostname: $CUSTOM_HOSTNAME"

  # Step 1: Login to Vault
  vault_login "$CLUSTER_CONTEXT" "$GATEWAY_NAMESPACE"

  # Step 2: Generate and deploy certificates for the custom hostname
  generate_certificates "$CUSTOM_HOSTNAME"
  create_k8s_secrets "$CLUSTER_CONTEXT" "$NGINX_NAMESPACE" "$SECRET_NAME"

  echo "Completed setup for cluster: $CLUSTER_CONTEXT"
done

# Cleanup temporary files
rm -f tls.crt tls.key ca.crt
echo "Vault integration with custom hostnames completed successfully!"
