#!/bin/bash

# Variables
VAULT_ADDR=https://vault.vault.svc.cluster.local:8200
VAULT_NAMESPACE="vault"
VAULT_RELEASE="vault"
VAULT_POD="vault-0"
VAULT_CLUSTER_CONTEXT="kind-cluster1"
CTX_CLUSTER1="kind-cluster1"  # Cluster 1 context
CTX_CLUSTER2="kind-cluster2"  # Cluster 2 context
CLUSTERS=("$CTX_CLUSTER1" "$CTX_CLUSTER2")  # Use these contexts
CLUSTERS=("cluster1" "cluster2")   # Names for your clusters
DOMAIN="svc.cluster.local" # Kubernetes service domain
WORKDIR=/tmp/vault3
NAMESPACES=("istio-system") # Namespaces to issue certificates for

mkdir -p $WORKDIR

# Cleanup Function
cleanup() {
    # Apply the wildcard certificate to the istio-system namespace in both clusters
    for CTX in $CTX_CLUSTER1 $CTX_CLUSTER2; do
        echo "delete cert..."

        kubectl delete secret cacerts default-wildcard-credential vault-wildcard-credential -n istio-system --context=$CTX --ignore-not-found   

        kubectl delete secret istio-reader-service-account-istio-remote-secret-token istio-remote-secret-cluster1 istio-remote-secret-cluster2 -n istio-system --context=$CTX --ignore-not-found     

        echo "Wildcard certificate applied to istio-system in $CTX."
    done
    rm -rvf ${WORKDIR}/*
    cp -rvf /tmp/vault/cluster-keys.json ${WORKDIR}/cluster-keys.json
    echo "Cleanup completed."
}

cleanup
echo "Waiting for the clenup..."
sleep 2

echo "Login to vault"
ROOT_TOKEN=$(jq -r '.root_token' ${WORKDIR}/cluster-keys.json)

# Login to Vault
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault login $ROOT_TOKEN

echo "Initializing Vault-based PKI setup..."

# Function to execute Vault commands via kubectl exec
vault_exec() {
  kubectl exec -it  $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault "$@"
}

echo "Fetching certificates and keys from Vault..."
# Fetch Intermediate Certificate
vault_exec read -format=json pki_int/cert/ca > "$WORKDIR/intermediate_cert.json"
jq -r '.data.certificate' "$WORKDIR/intermediate_cert.json" > "$WORKDIR/intermediate_cert.pem"

# Fetch Root Certificate
vault_exec read -format=json pki/cert/ca > "$WORKDIR/root_cert.json"
jq -r '.data.certificate' "$WORKDIR/root_cert.json" > "$WORKDIR/root-cert.pem"

#vault_exec read -field=private_key pki_int/keys/intermediate-ca > "$WORKDIR/ca-key.pem"

cp -rvf /tmp/vault2/ca-key.pem "$WORKDIR/ca-key.pem"

if [[ ! -s "$WORKDIR/ca-key.pem" ]]; then
  echo "Error: Private key for Intermediate CA is missing."
  exit 1
fi

# Combine Certificates
cat "$WORKDIR/intermediate_cert.pem" "$WORKDIR/root-cert.pem" > "$WORKDIR/full-cert-chain.pem"

# Validate Certificate Chain
openssl verify -CAfile "$WORKDIR/root-cert.pem" "$WORKDIR/full-cert-chain.pem"
if [[ $? -ne 0 ]]; then
  echo "Error: Certificate chain validation failed."
  exit 1
fi

# Apply `cacerts` secret to each cluster's Istio namespace
# for CTX in $CTX_CLUSTER1 $CTX_CLUSTER2; do
#   echo "Creating cacerts secret for Istio in context $CTX..."
#   kubectl create secret generic cacerts -n istio-system \
#     --from-file=ca-cert.pem="$WORKDIR/intermediate_cert.pem" \
#     --from-file=ca-key.pem="$WORKDIR/ca-key.pem" \
#     --from-file=cert-chain.pem="$WORKDIR/full-cert-chain.pem" \
#     --from-file=root-cert.pem="$WORKDIR/root-cert.pem" \
#     --context="$CTX" --dry-run=client -o yaml | kubectl apply -f -
# done

kubectl delete secret cacerts -n istio-system --context="$CTX_CLUSTER1" --ignore-not-found

kubectl create secret generic cacerts -n istio-system --context="$CTX_CLUSTER1"  \
    --from-file=ca-cert.pem="$WORKDIR/intermediate_cert.pem" \
    --from-file=ca-key.pem="$WORKDIR/ca-key.pem" \
    --from-file=cert-chain.pem="$WORKDIR/full-cert-chain.pem" \
    --from-file=root-cert.pem="$WORKDIR/root-cert.pem"


kubectl delete secret cacerts -n istio-system --context="$CTX_CLUSTER2" --ignore-not-found

kubectl create secret generic cacerts -n istio-system --context="$CTX_CLUSTER2"  \
    --from-file=ca-cert.pem="$WORKDIR/intermediate_cert.pem" \
    --from-file=ca-key.pem="$WORKDIR/ca-key.pem" \
    --from-file=cert-chain.pem="$WORKDIR/full-cert-chain.pem" \
    --from-file=root-cert.pem="$WORKDIR/root-cert.pem"

echo "cacerts secret has been successfully applied to all clusters."