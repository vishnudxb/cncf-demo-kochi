#!/bin/bash

# Variables
VAULT_NAMESPACE="vault"
VAULT_RELEASE="vault"
VAULT_CLUSTER_CONTEXT="kind-cluster1"
VAULT_HELM_REPO="https://helm.releases.hashicorp.com"
INTERMEDIATE_TTL="43800h"  # 5 years
ROOT_TTL="87600h"          # 10 years
TLS_CERT="vault.crt"
TLS_KEY="vault.key"
TLS_SECRET_NAME="vault-tls"

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

echo "Cleaning up previous deployment..."
kubectl delete namespace $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT --ignore-not-found
kubectl create namespace $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT

# Step 3: Generate TLS Certificates
echo "Generating TLS certificates for Vault..."
openssl req -newkey rsa:2048 -nodes -keyout $TLS_KEY -x509 -days 365 -out $TLS_CERT -subj "/CN=vault.$VAULT_NAMESPACE.svc.cluster.local" -addext "subjectAltName=DNS:vault.$VAULT_NAMESPACE.svc.cluster.local,DNS:localhost,IP:127.0.0.1"

if [ $? -ne 0 ]; then
    echo "Error: Failed to generate TLS certificates."
    exit 1
fi

# Step 4: Create TLS Secret in Kubernetes
echo "Creating TLS secret in Kubernetes..."
kubectl delete secret $TLS_SECRET_NAME -n $VAULT_NAMESPACE --ignore-not-found
kubectl create secret tls $TLS_SECRET_NAME --cert=$TLS_CERT --key=$TLS_KEY -n $VAULT_NAMESPACE
if [ $? -ne 0 ]; then
    echo "Error: Failed to create TLS secret."
    exit 1
fi

# Step 5: Deploy Vault with TLS Enabled
echo "Deploying Vault with TLS enabled..."
cat <<EOF > vault-helm-values.yaml
global:
  enabled: true
  tlsDisable: false
  namespace: $VAULT_NAMESPACE

server:
  service:
    type: LoadBalancer
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      config: |
        ui = true
        cluster_name = "vault-integrated-storage"
        storage "raft" {
          path = "/vault/data/"
        }
        listener "tcp" {
          address = "0.0.0.0:8200"
          cluster_address = "0.0.0.0:8201"
          tls_cert_file = "/vault/tls/tls.crt"
          tls_key_file = "/vault/tls/tls.key"
        }
        service_registration "kubernetes" {}

  affinity: |
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 1
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: vault
            topologyKey: kubernetes.io/hostname

  volumes:
    - name: vault-tls
      secret:
        secretName: $TLS_SECRET_NAME

  volumeMounts:
    - name: vault-tls
      mountPath: /vault/tls
      readOnly: true

  env:
    - name: VAULT_CACERT
      value: "/vault/tls/tls.crt"

  readinessProbe:
    httpGet:
      path: /v1/sys/health
      port: 8200
      scheme: HTTPS
  updateStrategy:
    type: RollingUpdate
EOF

helm upgrade --install $VAULT_RELEASE hashicorp/vault \
    --namespace $VAULT_NAMESPACE \
    -f ./vault-helm-values.yaml \
    --kube-context $VAULT_CLUSTER_CONTEXT --debug

# Step 6: Wait for Vault Pods to be Ready
echo "Waiting for Vault pods to be ready..."
kubectl rollout status statefulset/vault -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT --timeout=300s
#if [ $? -ne 0 ]; then
#    echo "Error: Vault pods did not become ready in time."
#    exit 1
#fi
sleep 15
# Step 7: Retrieve Vault Pod Name
VAULT_POD=$(kubectl get pods --namespace $VAULT_NAMESPACE --context="$VAULT_CLUSTER_CONTEXT" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

if [ -z "$VAULT_POD" ]; then
    echo "Error: Vault pod not found in namespace $VAULT_NAMESPACE on cluster $VAULT_CLUSTER_CONTEXT"
    exit 1
fi

# Step 8: Initialize and Unseal Vault
echo "Initializing Vault in cluster $VAULT_CLUSTER_CONTEXT..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- \
        vault operator init -ca-cert=/vault/tls/tls.crt -format=json  > vault-init.json

UNSEAL_KEY1=$(jq -r '.unseal_keys_b64[0]' vault-init.json)
UNSEAL_KEY2=$(jq -r '.unseal_keys_b64[1]' vault-init.json)
UNSEAL_KEY3=$(jq -r '.unseal_keys_b64[2]' vault-init.json)
ROOT_TOKEN=$(jq -r '.root_token' vault-init.json)

echo "Unsealing Vault in cluster $VAULT_CLUSTER_CONTEXT..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault operator unseal -ca-cert=/vault/tls/tls.crt $UNSEAL_KEY1
sleep 5
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault operator unseal -ca-cert=/vault/tls/tls.crt $UNSEAL_KEY2 
sleep 5
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault operator unseal -ca-cert=/vault/tls/tls.crt $UNSEAL_KEY3 
sleep 5

# Verify Vault unsealed state
VAULT_SEALED_STATUS=$(kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault status -ca-cert=/vault/tls/tls.crt | grep Sealed | awk '{print $2}')

if [ "$VAULT_SEALED_STATUS" != "false" ]; then
    echo "Vault is not fully unsealed. Exiting script."
    exit 1
fi

# Step 9: Enable PKI Secrets Engine
echo "Enabling PKI secrets engine..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault login -ca-cert=/vault/tls/tls.crt $ROOT_TOKEN 
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault secrets enable -ca-cert=/vault/tls/tls.crt pki 

echo "Configuring root CA in Vault..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault write -ca-cert=/vault/tls/tls.crt pki/root/generate/internal \
    common_name="mesh-root-ca" \
    ttl=$ROOT_TTL 

kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault write -ca-cert=/vault/tls/tls.crt pki/config/urls \
    issuing_certificates="https://vault.$VAULT_NAMESPACE.svc:8200/v1/pki/ca" \
    crl_distribution_points="https://vault.$VAULT_NAMESPACE.svc:8200/v1/pki/crl" 

echo "Vault deployed and configured successfully!"
