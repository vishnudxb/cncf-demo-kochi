#!/bin/bash

# Source the contexts for the clusters
source ./context.sh

VAULT_NAMESPACE="vault"
ISTIO_NAMESPACE="istio-system"
WORKDIR=/tmp/vault

cleanup() {
    echo "Starting cleanup process..."

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
    local CLUSTER_CONTEXT=$1

    echo "Retrieving certificates from Vault for cluster with context: $CLUSTER_CONTEXT"

    # Get the Vault pod in the current cluster context
    VAULT_POD=$(kubectl get pod -n $VAULT_NAMESPACE --context="$CLUSTER_CONTEXT" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$VAULT_POD" ]; then
        echo "Error: Could not find Vault pod in namespace $VAULT_NAMESPACE for context $CLUSTER_CONTEXT"
        exit 1
    fi

    echo "Login to vault"
    ROOT_TOKEN=$(jq -r '.root_token' ${WORKDIR}/cluster-keys.json)
    # Login to Vault
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault login $ROOT_TOKEN

    # Retrieve Intermediate CA Certificate
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context="$CLUSTER_CONTEXT" -- vault read -format=json pki_int/cert/ca | jq -r '.data.certificate' > ca-cert.pem

    # Retrieve Root CA Certificate
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context="$CLUSTER_CONTEXT" -- vault read -format=json pki/root | jq -r '.data.certificate' > root-cert.pem

    # Retrieve Intermediate Private Key
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context="$CLUSTER_CONTEXT" -- vault read -format=json pki_int/cert/ca | jq -r '.data.private_key' > ca-key.pem

    # Combine certificates to create Certificate Chain
    cat ca-cert.pem root-cert.pem > cert-chain.pem

    echo "Certificates retrieved for context $CLUSTER_CONTEXT and saved as ca-cert.pem, ca-key.pem, root-cert.pem, cert-chain.pem."
}

# Function to create Istio secrets
create_istio_secret() {
    local CLUSTER_CONTEXT=$1

    echo "Creating Istio secrets for cluster with context: $CLUSTER_CONTEXT"

    # Create the `cacerts` secret
    kubectl create secret generic cacerts -n $ISTIO_NAMESPACE \
        --context="$CLUSTER_CONTEXT" \
        --from-file=ca-cert.pem=ca-cert.pem \
        --from-file=ca-key.pem=ca-key.pem \
        --from-file=root-cert.pem=root-cert.pem \
        --from-file=cert-chain.pem=cert-chain.pem \
        --dry-run=client -o yaml | kubectl apply -n $ISTIO_NAMESPACE -f -

    echo "Istio secret 'cacerts' created successfully for context $CLUSTER_CONTEXT."
}

# Function to enable endpoint discovery
enable_endpoint_discovery() {
    local SOURCE_CONTEXT=$1
    local TARGET_CONTEXT=$2
    local TARGET_CLUSTER_NAME=$3

    echo "Enabling Endpoint Discovery from $SOURCE_CONTEXT to $TARGET_CONTEXT..."

    # Use istioctl to create the remote secret for the target cluster
    istioctl create-remote-secret \
        --context="$SOURCE_CONTEXT" \
        --name="$TARGET_CLUSTER_NAME" | kubectl -n $ISTIO_NAMESPACE apply --context="$TARGET_CONTEXT" -f -

    echo "Endpoint Discovery enabled from $SOURCE_CONTEXT to $TARGET_CONTEXT."
}

# Main function to configure both clusters
configure_cluster() {
    local CLUSTER_CONTEXT=$1
    local CLUSTER_NAME=$2

    echo "Starting configuration for cluster: $CLUSTER_NAME with context: $CLUSTER_CONTEXT"

    # Retrieve certificates from Vault
    retrieve_vault_certs "$CLUSTER_CONTEXT"

    # Create the Istio secrets in the target cluster
    create_istio_secret "$CLUSTER_CONTEXT"

    # Clean up temporary certificate files
    rm -f ca-cert.pem ca-key.pem root-cert.pem cert-chain.pem

    echo "Configuration completed for cluster: $CLUSTER_NAME with context: $CLUSTER_CONTEXT"
}

# Run cleanup first
cleanup

# Configure Cluster 1
configure_cluster "$CTX_CLUSTER1" "cluster1"

# Configure Cluster 2
configure_cluster "$CTX_CLUSTER2" "cluster2"

# Enable Endpoint Discovery between the clusters
enable_endpoint_discovery "$CTX_CLUSTER1" "$CTX_CLUSTER2" "cluster1"
enable_endpoint_discovery "$CTX_CLUSTER2" "$CTX_CLUSTER1" "cluster2"

echo "Multi-cluster setup with Endpoint Discovery completed successfully!"