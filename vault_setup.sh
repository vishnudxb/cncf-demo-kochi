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
TLS_CA="vault.ca"
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
openssl req -newkey rsa:2048 -nodes -keyout $TLS_KEY -x509 -days 365 -out $TLS_CERT \
  -subj "/CN=vault.vault.svc.cluster.local" \
  -addext "subjectAltName=DNS:vault-0.vault-internal,DNS:vault-1.vault-internal,DNS:vault-2.vault-internal,DNS:vault.vault.svc.cluster.local,DNS:localhost,IP:127.0.0.1"

cp $TLS_CERT $TLS_CA
if [ $? -ne 0 ]; then
    echo "Error: Failed to generate TLS certificates."
    exit 1
fi

# Step 4: Create TLS Secret in Kubernetes
echo "Creating TLS secret in Kubernetes..."
kubectl delete secret $TLS_SECRET_NAME -n $VAULT_NAMESPACE --ignore-not-found
kubectl create secret generic $TLS_SECRET_NAME -n $VAULT_NAMESPACE \
    --from-file=vault.crt=$TLS_CERT \
    --from-file=vault.key=$TLS_KEY \
    --from-file=vault.ca=$TLS_CA

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
    type: ClusterIP
  ha:
    activeService:
      enabled: false
    standbyService:
      enabled: false
    enabled: true
    replicas: 3
    raft:
      enabled: true
      config: |
        ui = true
        log_format = "json"
        cluster_name = "vault-integrated-storage"

        listener "tcp" {
          address            = "[::]:8200"
          cluster_address    = "[::]:8201"
          tls_cert_file = "/vault/tls/vault.crt"
          tls_key_file  = "/vault/tls/vault.key"
          tls_client_ca_file = "/vault/tls/vault.ca"
        }
        storage "raft" {
          path = "/vault/data"
            retry_join {
            leader_api_addr = "https://vault-0.vault-internal:8200"
            leader_ca_cert_file = "/vault/tls/vault.ca"
            leader_client_cert_file = "/vault/tls/vault.crt"
            leader_client_key_file = "/vault/tls/vault.key"
          }

          retry_join {
            leader_api_addr = "https://vault-1.vault-internal:8200"
            leader_ca_cert_file = "/vault/tls/vault.ca"
            leader_client_cert_file = "/vault/tls/vault.crt"
            leader_client_key_file = "/vault/tls/vault.key"
          }

          retry_join {
            leader_api_addr = "https://vault-2.vault-internal:8200"
            leader_ca_cert_file = "/vault/tls/vault.ca"
            leader_client_cert_file = "/vault/tls/vault.crt"
            leader_client_key_file = "/vault/tls/vault.key"
          }

          autopilot {
            cleanup_dead_servers = "true"
            last_contact_threshold = "200ms"
            last_contact_failure_threshold = "10m"
            max_trailing_logs = 250000
            min_quorum = 3
            server_stabilization_time = "10s"
          }
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
      value: "/vault/tls/vault.ca"

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
kubectl rollout status statefulset vault -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT --timeout=300s
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
        vault operator init -ca-cert=/vault/tls/vault.ca -format=json  > vault-init.json

UNSEAL_KEY1=$(jq -r '.unseal_keys_b64[0]' vault-init.json)
UNSEAL_KEY2=$(jq -r '.unseal_keys_b64[1]' vault-init.json)
UNSEAL_KEY3=$(jq -r '.unseal_keys_b64[2]' vault-init.json)
ROOT_TOKEN=$(jq -r '.root_token' vault-init.json)

# Array of unseal keys
UNSEAL_KEYS=("$UNSEAL_KEY1" "$UNSEAL_KEY2" "$UNSEAL_KEY3")

# List of Vault pod names
VAULT_PODS=("vault-0" "vault-1" "vault-2")

# Ensure pods join the Raft cluster
for pod in "${VAULT_PODS[@]}"; do
  echo "Checking if $pod has joined the Raft cluster..."
  if ! kubectl exec -n $VAULT_NAMESPACE $pod -- vault operator raft list-peers -ca-cert=/vault/tls/vault.ca | grep "$pod"; then
    echo "$pod has not joined the Raft cluster. Attempting to join..."
    kubectl exec -n $VAULT_NAMESPACE $pod -- \
      vault operator raft join -leader-ca-cert=/vault/tls/vault.ca https://vault-0.vault-internal:8200
      sleep 10
  else
    echo "$pod is already part of the Raft cluster."
  fi
done

# Unseal each pod using the unseal keys
for pod in "${VAULT_PODS[@]}"; do
  echo "Unsealing $pod..."
  for key in "${UNSEAL_KEYS[@]}"; do
    kubectl exec -n $VAULT_NAMESPACE $pod -- \
      vault operator unseal -ca-cert=/vault/tls/vault.ca $key
    sleep 5  # Optional delay between unseal attempts
  done
done

# Verify the unseal status
for pod in "${VAULT_PODS[@]}"; do
  echo "Checking unseal status of $pod..."
  kubectl exec -n $VAULT_NAMESPACE $pod -- vault status -ca-cert=/vault/tls/vault.ca
done

# Verify Vault unsealed state
VAULT_SEALED_STATUS=$(kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault status -ca-cert=/vault/tls/vault.ca | grep Sealed | awk '{print $2}')

if [ "$VAULT_SEALED_STATUS" != "false" ]; then
    echo "Vault is not fully unsealed. Exiting script."
    exit 1
fi

# Step 9: Enable PKI Secrets Engine
echo "Enabling PKI secrets engine..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault login -ca-cert=/vault/tls/vault.ca $ROOT_TOKEN 
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault secrets enable -ca-cert=/vault/tls/vault.ca pki 

echo "Configuring root CA in Vault..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault write -ca-cert=/vault/tls/vault.ca pki/root/generate/internal \
    common_name="svc.cluster.local" \
    issuer_name="cncf-kochi"
    ttl=$ROOT_TTL 

echo "List the issuer information for the root CA...."
ISSUER_REF=$(kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault list -ca-cert=/vault/tls/vault.ca  pki/issuers/ | tail -n1)

echo "List the issuer information for the root CA...."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- \
    vault read -ca-cert=/vault/tls/vault.ca pki/issuer/$ISSUER_REF | tail -n 6


echo "Create a role for the root CA..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- \
    vault write -ca-cert=/vault/tls/vault.ca pki/roles/cncf-kochi allow_any_name=true

echo "Configure the CA and CRL URLs..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- vault write -ca-cert=/vault/tls/vault.ca pki/config/urls \
    issuing_certificates="https://vault.$VAULT_NAMESPACE.svc:8200/v1/pki/ca" \
    crl_distribution_points="https://vault.$VAULT_NAMESPACE.svc:8200/v1/pki/crl" 


echo "create an intermediate CA using the root CA you regenerated..."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- \
    vault secrets enable -ca-cert=/vault/tls/vault.ca -path=pki_int pki

echo "Tune the pki_int secrets engine to issue certificates with a maximum time-to-live (TTL) of 43800 hours."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- \
    vault secrets tune -ca-cert=/vault/tls/vault.ca -max-lease-ttl=43800h pki_int

echo "Generate an intermediate CSR as cncf_intermediate.csr"
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- \
    vault write -ca-cert=/vault/tls/vault.ca -format=json pki_int/intermediate/generate/internal \
        common_name="svc.cluster.local Intermediate Authority" \
        issuer_name="svc-cluster-local-intermediate" | jq -r '.data.csr' > cncf_intermediate.csr

if [ ! -f cncf_intermediate.csr ]; then
    echo "Error: cncf_intermediate.csr was not created."
    exit 1
fi

echo "Sign the intermediate certificate with the root CA private key"
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- \
    vault write -ca-cert=/vault/tls/vault.ca -format=json pki/root/sign-intermediate \
        csr=@cncf_intermediate.csr \
        format=pem_bundle ttl="43800h" \
        | jq -r '.data.certificate' > cncfintermediate.cert.pem

if [ ! -f cncfintermediate.cert.pem ]; then
    echo "Error: cncfintermediate.cert.pem was not created."
    exit 1
fi


echo "Once the CSR is signed and the root CA returns a certificate, it can be imported back into Vault."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- \
    vault write -ca-cert=/vault/tls/vault.ca pki_int/intermediate/set-signed certificate=@cncfintermediate.cert.pem

# Create a role named svc.cluster.local which allows subdomains, and specify the default issuer ref ID as the value of issuer_ref.

echo "Set default issuer for pki_int"
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- \
    vault write -ca-cert=/vault/tls/vault.ca pki_int/config/issuers \
    default_issuer_id="$(kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- \
    vault list -ca-cert=/vault/tls/vault.ca pki/issuers | tail -n 1)"

echo "creating vault role.."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- \
    vault write  -ca-cert=/vault/tls/vault.ca pki_int/roles/cncf-kochi \
        issuer_ref="$(kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault read  -ca-cert=/vault/tls/vault.ca -field=default pki_int/config/issuers)" \
        allowed_domains="example.com" \
        allow_subdomains=true \
        max_ttl="720h"

echo "request certificates.."
kubectl exec -n $VAULT_NAMESPACE $VAULT_POD --context $VAULT_CLUSTER_CONTEXT -- \
    vault write -ca-cert=/vault/tls/vault.ca pki_int/issue/cncf-kochi common_name="istio-ingressgateway.istio-system.svc.cluster.local" ttl="24h"

echo "Vault deployed and configured successfully!"
