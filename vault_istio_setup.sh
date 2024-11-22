#!/bin/bash

# Variables
VAULT_NAMESPACE="vault"
VAULT_RELEASE="vault"
VAULT_CLUSTER_CONTEXT="kind-cluster1"
CLUSTER1_CONTEXT="kind-cluster1"
CLUSTER2_CONTEXT="kind-cluster2"
VAULT_HELM_REPO="https://helm.releases.hashicorp.com"
INTERMEDIATE_TTL="43800h"  # 5 years
ROOT_TTL="87600h"          # 10 years

# Step 1: Validate Vault Cluster Context
echo "Vault will be deployed in cluster context: $VAULT_CLUSTER_CONTEXT"
kubectl config use-context $VAULT_CLUSTER_CONTEXT
if [ $? -ne 0 ]; then
    echo "Error: Unable to set context to $VAULT_CLUSTER_CONTEXT. Please check your kubeconfig."
    exit 1
fi

# Step 2: Add the Vault Helm repo and update
helm repo add hashicorp $VAULT_HELM_REPO
helm repo update

# Step 3: Install Vault in HA mode with Raft storage in the selected cluster

kubectl delete namespace $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT || echo "deleting and recreating vault ns.."

kubectl create namespace $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT
helm upgrade --install $VAULT_RELEASE hashicorp/vault \
    --namespace $VAULT_NAMESPACE \
    --set "server.ha.enabled=true" \
    --set "server.affinity=" \
    --set "server.extraArgs=-config=/tmp/storageconfig.hcl" \
    --set "server.service.apiAddress=http://vault-internal.vault.svc.cluster.local:8200" \
    --set "server.service.clusterAddress=http://vault-internal.vault.svc.cluster.local:8201" \
    --set "server.readinessProbe.httpGet.path=/v1/sys/health" \
    --set "server.readinessProbe.httpGet.port=8200" \
    --set "server.listener.address=0.0.0.0:8200" \
    --set "server.storage.raft.enabled=true" \
    --set "server.storage.raft.path=/vault/data" \
    --set "server.apiAddr=http://vault-internal.vault.svc.cluster.local:8200" \
    --set "server.clusterAddr=http://vault-internal.vault.svc.cluster.local:8201" \
    --kube-context $VAULT_CLUSTER_CONTEXT


# Wait for Vault pod to be ready
echo "Waiting for Vault pod to be ready in cluster: $VAULT_CLUSTER_CONTEXT..."
kubectl wait --namespace $VAULT_NAMESPACE --for=condition=ready pod -l app.kubernetes.io/name=vault \
    --context $VAULT_CLUSTER_CONTEXT --timeout=300s

# Step 4: Retrieve Vault Pod Name
VAULT_POD=$(kubectl get pods --namespace $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT \
              -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

if [ -z "$VAULT_POD" ]; then
    echo "Error: Vault pod not found in namespace $VAULT_NAMESPACE on cluster $VAULT_CLUSTER_CONTEXT"
    exit 1
fi

# Step 5: Initialize and Unseal Vault
echo "Initializing Vault in cluster $VAULT_CLUSTER_CONTEXT..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault operator init -format=json > vault-init.json

UNSEAL_KEY1=$(jq -r '.unseal_keys_b64[0]' vault-init.json)
UNSEAL_KEY2=$(jq -r '.unseal_keys_b64[1]' vault-init.json)
UNSEAL_KEY3=$(jq -r '.unseal_keys_b64[2]' vault-init.json)
ROOT_TOKEN=$(jq -r '.root_token' vault-init.json)

echo "Unsealing Vault in cluster $VAULT_CLUSTER_CONTEXT..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault operator unseal $UNSEAL_KEY1
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault operator unseal $UNSEAL_KEY2
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault operator unseal $UNSEAL_KEY3

# Step 6: Enable PKI Secrets Engine
echo "Enabling PKI secrets engine..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault login $ROOT_TOKEN
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault secrets enable pki

echo "Configuring root CA in Vault..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault write pki/root/generate/internal \
    common_name="mesh-root-ca" \
    ttl=$ROOT_TTL

kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault write pki/config/urls \
    issuing_certificates="http://vault.$VAULT_NAMESPACE.svc:8200/v1/pki/ca" \
    crl_distribution_points="http://vault.$VAULT_NAMESPACE.svc:8200/v1/pki/crl"
