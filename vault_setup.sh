#!/bin/bash

# Variables
VAULT_NAMESPACE="vault"
VAULT_RELEASE="vault"
VAULT_SERVICE_NAME="vault-internal" 
K8S_CLUSTER_NAME="cluster.local"
VAULT_CLUSTER_CONTEXT="kind-cluster1"
WORKDIR=/tmp/vault
VAULT_HELM_REPO="https://helm.releases.hashicorp.com"
INTERMEDIATE_TTL="43800h"  # 5 years
ROOT_TTL="87600h"          # 10 years
TLS_CERT="vault.crt"
TLS_KEY="vault.key"
TLS_CA="vault.ca"
TLS_SECRET_NAME="vault-tls"
CRL_DIST="https://vault.vault.svc.cluster.local:8200/v1/pki/crl"
ISSUE_URL="https://vault.vault.svc.cluster.local:8200/v1/pki/ca"

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
kubectl delete csr vault.svc --ignore-not-found
rm -rvf /tmp/vault
mkdir -p /tmp/vault

kubectl create namespace $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT

kubectl config set-context kind-cluster1

echo "Generate the private key....."
openssl genrsa -out ${WORKDIR}/vault.key 2048


echo "Create the CSR configuration file....."

cat > ${WORKDIR}/vault-csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
encrypt_key = yes
default_md = sha256
distinguished_name = kubelet_serving
req_extensions = v3_req
[ kubelet_serving ]
O = system:nodes
CN = system:node:*.${VAULT_NAMESPACE}.svc.${K8S_CLUSTER_NAME}
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.${VAULT_SERVICE_NAME}
DNS.2 = *.${VAULT_SERVICE_NAME}.${VAULT_NAMESPACE}.svc.${K8S_CLUSTER_NAME}
DNS.3 = *.${VAULT_NAMESPACE}
IP.1 = 127.0.0.1
EOF


echo "Generate the CSR..."
openssl req -new -key ${WORKDIR}/vault.key -out ${WORKDIR}/vault.csr -config ${WORKDIR}/vault-csr.conf


echo "issue the certificate...."

cat > ${WORKDIR}/csr.yaml <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
   name: vault.svc
spec:
   signerName: kubernetes.io/kubelet-serving
   expirationSeconds: 8640000
   request: $(cat ${WORKDIR}/vault.csr|base64|tr -d '\n')
   usages:
   - digital signature
   - key encipherment
   - server auth
EOF


echo "Send the CSR to Kubernetes....."
kubectl create -f ${WORKDIR}/csr.yaml


echo "Approve the CSR in Kubernetes...."
kubectl certificate approve vault.svc

echo "Confirm the certificate was issued..."
kubectl get csr vault.svc

echo "Retrieve the certificate"
kubectl get csr vault.svc -o jsonpath='{.status.certificate}' | openssl base64 -d -A -out ${WORKDIR}/vault.crt


echo "Retrieve Kubernetes CA certificate...."
kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d > ${WORKDIR}/vault.ca

echo "Create the TLS secret...."
kubectl create secret generic vault-ha-tls -n $VAULT_NAMESPACE --from-file=vault.key=${WORKDIR}/vault.key --from-file=vault.crt=${WORKDIR}/vault.crt --from-file=vault.ca=${WORKDIR}/vault.ca


echo "create custom helm files..."
cat > ${WORKDIR}/overrides.yaml <<EOF
global:
   enabled: true
   tlsDisable: false
injector:
   enabled: true
server:
   extraEnvironmentVars:
      VAULT_CACERT: /vault/userconfig/vault-ha-tls/vault.ca
      VAULT_TLSCERT: /vault/userconfig/vault-ha-tls/vault.crt
      VAULT_TLSKEY: /vault/userconfig/vault-ha-tls/vault.key
   volumes:
      - name: userconfig-vault-ha-tls
        secret:
         defaultMode: 420
         secretName: vault-ha-tls
   volumeMounts:
      - mountPath: /vault/userconfig/vault-ha-tls
        name: userconfig-vault-ha-tls
        readOnly: true
   standalone:
      enabled: false
   affinity: ""
   ha:
      enabled: true
      replicas: 3
      raft:
         enabled: true
         setNodeId: true
         config: |
            cluster_name = "vault-integrated-storage"
            ui = true
            listener "tcp" {
               tls_disable = 0
               address = "[::]:8200"
               cluster_address = "[::]:8201"
               tls_cert_file = "/vault/userconfig/vault-ha-tls/vault.crt"
               tls_key_file  = "/vault/userconfig/vault-ha-tls/vault.key"
               tls_client_ca_file = "/vault/userconfig/vault-ha-tls/vault.ca"
            }
            storage "raft" {
              path = "/vault/data"
            }
            disable_mlock = true
            service_registration "kubernetes" {}
EOF


echo "Deploy the Cluster..."

helm install -n $VAULT_NAMESPACE $VAULT_RELEASE hashicorp/vault -f ${WORKDIR}/overrides.yaml

echo "display pods..."
kubectl -n $VAULT_NAMESPACE get pods

sleep 15

echo "Initialize vault-0 with one key share and one key threshold...."
kubectl exec -it vault-0 -n $VAULT_NAMESPACE -- vault operator init -key-shares=1 -key-threshold=1 -format=json > ${WORKDIR}/cluster-keys.json
sleep 1

echo "cluster keys file: $(cat ${WORKDIR}/cluster-keys.json)"

echo "Display the unseal key found in cluster-keys.json..."
jq -r ".unseal_keys_b64[]" ${WORKDIR}/cluster-keys.json

echo "Create a variable named VAULT_UNSEAL_KEY to capture the Vault unseal key..."
VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[]" ${WORKDIR}/cluster-keys.json)

echo "Unseal Vault running on the vault-0 pod..."
kubectl exec -it vault-0 -n $VAULT_NAMESPACE  -- vault operator unseal $VAULT_UNSEAL_KEY

sleep 5

echo "Joining vault-1 to the Raft cluster..."
kubectl exec -it vault-1 -n $VAULT_NAMESPACE -- sh -c "
vault operator raft join -address=https://vault-1.vault-internal:8200 \
  -leader-ca-cert=\"\$(cat /vault/userconfig/vault-ha-tls/vault.ca)\" \
  -leader-client-cert=\"\$(cat /vault/userconfig/vault-ha-tls/vault.crt)\" \
  -leader-client-key=\"\$(cat /vault/userconfig/vault-ha-tls/vault.key)\" \
  https://vault-0.vault-internal:8200
"


echo "unseal vault-1......."
kubectl exec -it vault-1 -n $VAULT_NAMESPACE  -- vault operator unseal $VAULT_UNSEAL_KEY

sleep 5

echo "Joining vault-2 to the Raft cluster..."
kubectl exec -it vault-2 -n $VAULT_NAMESPACE -- sh -c "
vault operator raft join -address=https://vault-2.vault-internal:8200 \
  -leader-ca-cert=\"\$(cat /vault/userconfig/vault-ha-tls/vault.ca)\" \
  -leader-client-cert=\"\$(cat /vault/userconfig/vault-ha-tls/vault.crt)\" \
  -leader-client-key=\"\$(cat /vault/userconfig/vault-ha-tls/vault.key)\" \
  https://vault-0.vault-internal:8200
"


echo "unseal vault-2......."
kubectl exec -it vault-2  -n $VAULT_NAMESPACE -- vault operator unseal $VAULT_UNSEAL_KEY

echo "Get the root token...."
export CLUSTER_ROOT_TOKEN=$(cat ${WORKDIR}/cluster-keys.json | jq -r ".root_token")

echo "Login to vault........"
kubectl exec -it vault-0 -n $VAULT_NAMESPACE -- vault login $CLUSTER_ROOT_TOKEN


echo "List the raft peers........."
kubectl exec -it vault-0 -n $VAULT_NAMESPACE -- vault operator raft list-peers

echo "Print the HA status..."
kubectl exec -it vault-0 -n $VAULT_NAMESPACE -- vault status