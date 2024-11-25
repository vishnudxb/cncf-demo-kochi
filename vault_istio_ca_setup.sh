#!/bin/bash

# Variables
VAULT_NAMESPACE="vault"
VAULT_RELEASE="vault"
VAULT_POD="vault-0"
VAULT_CLUSTER_CONTEXT="kind-cluster1"
WORKDIR=/tmp/vault
INTERMEDIATE_TTL="43800h"  # 5 years
ROOT_TTL="87600h"          # 10 years
CRL_DIST="https://vault.vault.svc.cluster.local:8200/v1/pki/crl"
ISSUE_URL="https://vault.vault.svc.cluster.local:8200/v1/pki/ca"

# Cleanup Function
cleanup() {
    echo "Starting cleanup process..."

    # Delete Intermediate PKI Engine
    echo "Deleting intermediate PKI engine..."
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
        vault secrets disable pki_int || echo "Intermediate PKI engine already removed."

    # Delete Root PKI Engine
    echo "Deleting root PKI engine..."
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
        vault secrets disable pki || echo "Root PKI engine already removed."

    # Remove temporary files
    echo "Cleaning up temporary files..."
    rm -rvf cncfcaroot-2024.crt cncf_intermediate_csr.json /tmp/cncf_intermediate.csr /tmp/cncfintermediate.cert.pem cncfintermediate_cert.json
    echo "Temporary files removed."

    echo "Cleanup completed."
}

cleanup
echo "Waiting for the clenup..."
sleep 15

echo "Login to vault"
ROOT_TOKEN=$(jq -r '.root_token' ${WORKDIR}/cluster-keys.json)

# Login to Vault
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault login $ROOT_TOKEN

# Enable and configure Root PKI
echo "Enabling PKI secrets engine..."
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault secrets enable pki
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault secrets tune -max-lease-ttl=$ROOT_TTL pki

echo "Enable and tune Intermediate PKI..."
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault secrets enable -path=pki_int pki
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault secrets tune -max-lease-ttl=$INTERMEDIATE_TTL pki_int

# Generate Root CA
echo "Generate root CA in vault..."
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
    vault write -field=certificate pki/root/generate/internal \
    common_name="*.*.svc.cluster.local" ttl=$ROOT_TTL > cncfcaroot-2024.crt

# Generate Intermediate CSR
echo "Generating Intermediate CSR..."
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
    vault write -format=json pki_int/intermediate/generate/internal \
    common_name="*.*.svc.cluster.local" > cncf_intermediate_csr.json
jq -r '.data.csr' cncf_intermediate_csr.json > /tmp/cncf_intermediate.csr

# Configure URLs
echo "Configuring ROOT CA URLs..."
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context=$VAULT_CLUSTER_CONTEXT -- \
    vault write pki/config/urls \
    issuing_certificates="$ISSUE_URL" \
    crl_distribution_points="$CRL_DIST"

echo "Configuring Intermediate CA URLs..."
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
    vault write pki_int/config/urls \
    issuing_certificates="$ISSUE_URL" \
    crl_distribution_points="$CRL_DIST"

# Sign Intermediate Certificate
echo "Copy the file /tmp/tmp/cncf_intermediate.csr"
kubectl cp /tmp/cncf_intermediate.csr $VAULT_NAMESPACE/$VAULT_POD:/tmp/cncf_intermediate.csr --context=$VAULT_CLUSTER_CONTEXT

echo "Signing Intermediate Certificate..."

kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
    vault write -format=json pki/root/sign-intermediate \
    csr=@/tmp/cncf_intermediate.csr \
    format=pem_bundle ttl=$INTERMEDIATE_TTL > cncfintermediate_cert.json
jq -r '.data.certificate' cncfintermediate_cert.json > /tmp/cncfintermediate.cert.pem

# Import Signed Certificate
echo "Importing Signed Intermediate Certificate..."
kubectl cp /tmp/cncfintermediate.cert.pem $VAULT_NAMESPACE/$VAULT_POD:/tmp/cncfintermediate.cert.pem --context=$VAULT_CLUSTER_CONTEXT

kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
    vault write pki_int/intermediate/set-signed certificate=@/tmp/cncfintermediate.cert.pem



# export ISSUE_REF=$(kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context=$VAULT_CLUSTER_CONTEXT -- vault list pki_int/issuers | tail -n 1)

export ISSUER_REF=$(kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context=$VAULT_CLUSTER_CONTEXT -- vault list -format=json pki_int/issuers | jq -r '.[0]')

if [ -z "$ISSUER_REF" ]; then
  echo "Error: Unable to fetch a valid issuer reference. Ensure the intermediate CA is configured correctly."
  exit 1
fi
echo "Using Issuer Reference: $ISSUER_REF"


# Create PKI Roles

# DONT USE IN PRODUCTION WITH allow_any_name=true 

echo "Creating roles for multiple domains..."
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
    vault write pki_int/roles/cncf-kochi \
    allow_any_name=true \
    allow_wildcard_certificates=true \
    allow_ip_sans=true \
    allow_localhost=true \
    max_ttl="720h" \
    issuer_ref="$ISSUER_REF"

# Issue Certificates
echo "Issuing certificates for specified domains..."
for DOMAIN in "*.istio-system.svc.cluster.local" "*.default.svc.cluster.local" "*.vault.svc.cluster.local"; do
  kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context=$VAULT_CLUSTER_CONTEXT -- \
  vault write pki_int/issue/cncf-kochi \
      common_name="$DOMAIN" \
      ttl="24h" 

  if [ $? -ne 0 ]; then
    echo "Error: Failed to issue certificate for $DOMAIN."
    exit 1
  fi
done

echo "Vault CA and Intermediate certificates deployed and configured successfully!"