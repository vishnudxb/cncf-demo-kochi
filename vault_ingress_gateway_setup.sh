#!/bin/bash

# Variables
VAULT_ADDR="https://vault-0.vault-internal:8200"  # Replace with your Vault address
VAULT_ROLE="istio-ca"                    # Vault role configured for Kubernetes auth
CERT_TTL="8760h"                         # Certificate validity (1 year)

# Cluster and namespace configurations
CLUSTERS=("kind-cluster1" "kind-cluster2")
NAMESPACES=("istio-system" "istio-system")
REMOTE_SECRETS=("cluster1" "cluster2")
INGRESS_SECRETS=("istio-ingressgateway-certs" "istio-ingressgateway-ca-certs")
EGRESS_SECRETS=("istio-egressgateway-certs" "istio-egressgateway-ca-certs")

# Function: Login to Vault using Kubernetes service account
vault_login() {
  echo "Using Vault root token from environment variable..."

  # Fetch the root token from the environment variable
  VAULT_TOKEN="${VAULT_ROOT_TOKEN}"

  if [[ -z "$VAULT_TOKEN" ]]; then
    echo "Error: Vault root token is not set in the VAULT_ROOT_TOKEN environment variable."
    exit 1
  fi

  echo "Successfully set Vault root token from environment variable."
}

# Function: Fetch Vault Root Certificate
fetch_vault_root_cert() {
  echo "Fetching Vault CA root certificate..."
  ROOT_CERT=$(curl -s --header "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/pki/ca/pem" | sed 's/\\n/\n/g')

  if [[ -z "$ROOT_CERT" ]]; then
    echo "Error: Failed to fetch Vault root certificate."
    exit 1
  fi

  echo "$ROOT_CERT" > ca.crt
  echo "Root certificate saved to ca.crt."
}

# Function: Create ConfigMap for Root Certificate
create_root_cert_configmap() {
  local cluster_context=$1
  local namespace=$2
  echo "Creating ConfigMap for root certificate in cluster: $cluster_context..."

  kubectl --context="$cluster_context" create configmap istio-ca-root-cert \
    --from-file=ca.crt=ca.crt \
    -n "$namespace" --dry-run=client -o yaml | kubectl --context="$cluster_context" apply -f -

  echo "ConfigMap for root certificate created in cluster: $cluster_context."
}

# Function: Create Remote Secrets for Endpoint Discovery
create_remote_secrets() {
  local from_context=$1
  local to_context=$2
  local remote_name=$3

  echo "Creating remote secret for $from_context to $to_context..."
  istioctl create-remote-secret --context="$from_context" --name="$remote_name" | kubectl apply -f - --context="$to_context"
  echo "Remote secret applied from $from_context to $to_context."
}

# Function: Generate certificates using Vault
generate_certificates() {
  local common_name=$1
  echo "Generating certificate for $common_name..."
  CERT_OUTPUT=$(curl -s --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST --data '{"common_name": "'"$common_name"'", "ttl": "'"$CERT_TTL"'"}' \
    "$VAULT_ADDR/v1/pki/issue/$VAULT_ROLE")

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

# Function: Create Kubernetes secrets for Gateways
create_gateway_secrets() {
  local cluster_context=$1
  local namespace=$2
  local secret_name=$3

  echo "Creating Kubernetes secret ($secret_name) in cluster: $cluster_context, namespace: $namespace..."

  kubectl --context="$cluster_context" create secret tls "$secret_name" \
    --cert=tls.crt \
    --key=tls.key \
    -n "$namespace" --dry-run=client -o yaml | kubectl --context="$cluster_context" apply -f -

  kubectl --context="$cluster_context" create secret generic "$secret_name-ca" \
    --from-file=ca.crt=ca.crt \
    -n "$namespace" --dry-run=client -o yaml | kubectl --context="$cluster_context" apply -f -

  echo "Secret $secret_name created in cluster: $cluster_context."
}

# Main Execution
for i in "${!CLUSTERS[@]}"; do
  CLUSTER_CONTEXT="${CLUSTERS[$i]}"
  NAMESPACE="${NAMESPACES[$i]}"
  REMOTE_SECRET="${REMOTE_SECRETS[$i]}"

  echo "Processing trust setup for cluster: $CLUSTER_CONTEXT"

  # Step 1: Login to Vault
  vault_login "$CLUSTER_CONTEXT" "$NAMESPACE"

  # Step 2: Fetch and Deploy Vault Root Certificate
  fetch_vault_root_cert
  create_root_cert_configmap "$CLUSTER_CONTEXT" "$NAMESPACE"

  # Step 3: Generate and Deploy Ingress Gateway Certificates
  generate_certificates "istio-ingressgateway.$NAMESPACE.svc.cluster.local"
  create_gateway_secrets "$CLUSTER_CONTEXT" "$NAMESPACE" "${INGRESS_SECRETS[$i]}"

  # Step 4: Generate and Deploy Egress Gateway Certificates
  generate_certificates "istio-egressgateway.$NAMESPACE.svc.cluster.local"
  create_gateway_secrets "$CLUSTER_CONTEXT" "$NAMESPACE" "${EGRESS_SECRETS[$i]}"
done

# Step 5: Create Remote Secrets for Endpoint Discovery
create_remote_secrets "${CLUSTERS[0]}" "${CLUSTERS[1]}" "${REMOTE_SECRETS[0]}"
create_remote_secrets "${CLUSTERS[1]}" "${CLUSTERS[0]}" "${REMOTE_SECRETS[1]}"

# Cleanup temporary files
rm -f tls.crt tls.key ca.crt
echo "Trust and gateway certificate setup for Istio multi-primary completed successfully!"
