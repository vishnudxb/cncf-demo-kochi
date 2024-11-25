#!/bin/bash

VAULT_NAMESPACE="vault"
ISTIO_NAMESPACE="istio-system"
VAULT_TOKEN_DIR=/tmp/vault
VAULT_NAMESPACE="vault"
CLUSTER1_CONTEXT="kind-cluster1"
CLUSTER2_CONTEXT="kind-cluster2"
WORKDIR="/tmp/vault_istio_certs"
mkdir -p $WORKDIR



cleanup() {
    echo "Starting cleanup process..."

    rm -rf $WORKDIR
    # Delete Istio secrets in both clusters
    kubectl delete secret cacerts -n $ISTIO_NAMESPACE --context="$CTX_CLUSTER1" --ignore-not-found
    kubectl delete secret cacerts -n $ISTIO_NAMESPACE --context="$CTX_CLUSTER2" --ignore-not-found

    # Remove any temporary certificate files
    rm -f ca-cert.pem ca-key.pem root-cert.pem cert-chain.pem
    sleep 3

    echo "Cleanup process completed."
}

# Function to retrieve certificates from Vault
retrieve_vault_certs() {

    echo "Retrieving certificates from Vault for cluster with context: $VAULT_CONTEXT"

    # Get the Vault pod in the current cluster context
    VAULT_POD=$(kubectl get pod -n $VAULT_NAMESPACE --context="$VAULT_CONTEXT" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$VAULT_POD" ]; then
        echo "Error: Could not find Vault pod in namespace $VAULT_NAMESPACE for context $CLUSTER_CONTEXT"
        exit 1
    fi

    echo "Found Vault pod: $VAULT_POD" 
    echo "Login to vault"
    ROOT_TOKEN=$(jq -r '.root_token' /tmp/vault/cluster-keys.json)
    # Login to Vault
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CONTEXT -- vault login $ROOT_TOKEN

    # Retrieve Intermediate CA Certificate
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context="$VAULT_CONTEXT" -- vault read -format=json pki_int/cert/ca | jq -r '.data.certificate' > $WORKDIR/ca-cert.pem

    # Retrieve Root CA Certificate
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context="$VAULT_CONTEXT" -- vault read -format=json pki/root | jq -r '.data.certificate' > $WORKDIR/root-cert.pem

    # Retrieve Intermediate Private Key
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context="$VAULT_CONTEXT" -- vault read -format=json pki_int/cert/ca | jq -r '.data.private_key' > $WORKDIR/ca-key.pem

    # Combine certificates to create Certificate Chain
    cat $WORKDIR/ca-cert.pem $WORKDIR/root-cert.pem > $WORKDIR/cert-chain.pem

    echo "Certificates retrieved for context $VAULT_CONTEXT and saved as ca-cert.pem, ca-key.pem, root-cert.pem, cert-chain.pem."
}

# Function to create Istio secrets
create_istio_secret() {
    local CONTEXT=$1

    echo "Creating Istio secrets for cluster with context: $CONTEXT..."

    # Create the `cacerts` secret
    kubectl create secret generic cacerts -n $ISTIO_NAMESPACE \
        --context="$$CONTEXT" \
        --from-file=ca-cert.pem=$WORKDIR/ca-cert.pem \
        --from-file=ca-key.pem=$WORKDIR/ca-key.pem \
        --from-file=root-cert.pem=$WORKDIR/root-cert.pem \
        --from-file=cert-chain.pem=$WORKDIR/cert-chain.pem \
        --dry-run=client -o yaml | kubectl apply -n $ISTIO_NAMESPACE -f -

    echo "Istio secret 'cacerts' created successfully for context $CLUSTER_CONTEXT."
}

# Function to enable endpoint discovery
enable_endpoint_discovery() {
    local CONTEXT1=$1
    local CONTEXT2=$2
    echo "Creating remote secrets for clusters $CONTEXT1 and $CONTEXT2..."

    # Install a remote secret in cluster2 that provides access to cluster1's API server
    istioctl create-remote-secret \
        --context="${CONTEXT1}" \
        --name=cluster1 | kubectl apply -f - --context="${CONTEXT2}"

    # Install a remote secret in cluster1 that provides access to cluster2's API server
    istioctl create-remote-secret \
        --context="${CONTEXT2}" \
        --name=cluster2 | kubectl apply -f - --context="${CONTEXT1}"

    echo "Endpoint discovery setup complete for clusters $CONTEXT1 and $CONTEXT2."
}

# Run cleanup first
cleanup
retrieve_certs_from_vault

create_istio_secrets $CLUSTER1_CONTEXT
create_istio_secrets $CLUSTER2_CONTEXT
enable_endpoint_discovery "kind-cluster1" "kind-cluster2"

echo "Multi-cluster setup with Endpoint Discovery completed successfully!"