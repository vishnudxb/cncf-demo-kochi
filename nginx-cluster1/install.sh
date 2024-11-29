#!/bin/bash

VAULT_ADDR=https://vault.vault.svc.cluster.local:8200
VAULT_NAMESPACE="vault"
VAULT_RELEASE="vault"
VAULT_POD="vault-0"
VAULT_CLUSTER_CONTEXT="kind-cluster1"
CTX_CLUSTER1="kind-cluster1"  # Cluster 1 context
CTX_CLUSTER2="kind-cluster2"  # Cluster 2 context
ROLE_NAME="nginx-role"
COMMON_NAME="ngx-svc-cluster1.default.svc.cluster.local"
ALT_NAMES="ngx-svc-cluster1.default.svc.cluster.local,ngx-svc-cluster1,172.18.0.150"
TTL="24h"
MAX_TTL="720h"
K8S_SECRET_NAME="nginx-tls-secret"
NAMESPACE="istio-system"
WORKDIR=/tmp/vault4


mkdir -p $WORKDIR


# Cleanup Function
cleanup() {
    echo "cleanup..."

    kubectl delete -f ./ --context=$CTX_CLUSTER1 --ignore-not-found
    kubectl delete secret $K8S_SECRET_NAME --context=$CTX_CLUSTER1 -n istio-system
    kubectl delete configmap nginx-config --context=$CTX_CLUSTER1
    rm -rvf ${WORKDIR}/*
    cp -rvf /tmp/vault/cluster-keys.json ${WORKDIR}/cluster-keys.json
    echo "Cleanup completed."
    kubectl --context="$CTX_CLUSTER2" delete pod curl-pod --force || echo "Pod is not running...."
}

cleanup
echo "Waiting for the clenup..."
sleep 2

echo "Login to vault"
ROOT_TOKEN=$(jq -r '.root_token' ${WORKDIR}/cluster-keys.json)

# Login to Vault
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault login $ROOT_TOKEN


# Function to execute Vault commands via kubectl exec
vault_exec() {
  kubectl exec -it  $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault "$@"
}

# Step 1: Create or verify the Vault role
echo "Creating or verifying Vault role..."
vault_exec write pki_int/roles/$ROLE_NAME \
    allow_subdomains=true \
    allow_any_name=true \
    allow_wildcard_certificates=true \
    allow_ip_sans=true \
    allow_localhost=true \
    allowed_domains="ngx-svc-cluster1.default.svc.cluster.local" \
    max_ttl="$MAX_TTL"

# Step 2: Issue a certificate for the nginx service
echo "Issuing certificate for $COMMON_NAME..."
vault_exec write -format=json pki_int/issue/$ROLE_NAME \
    common_name="$COMMON_NAME" \
    alt_names="$ALT_NAMES" \
    ip_sans="172.18.0.150" \
    ttl="$TTL" > ${WORKDIR}/nginx-cert.json

# Extract certificate, key, and CA
echo "Extracting certificate, private key, and CA..."
jq -r .data.certificate < ${WORKDIR}/nginx-cert.json > ${WORKDIR}/tls.crt
jq -r .data.private_key < ${WORKDIR}/nginx-cert.json > ${WORKDIR}/tls.key


echo "Get root ca to ${WORKDIR}/root_ca.crt...."
vault_exec read  -format=json pki/cert/ca > ${WORKDIR}/root_ca.json

jq -r .data.certificate < ${WORKDIR}/root_ca.json > ${WORKDIR}/root_ca.crt


echo "Get root ca to  ${WORKDIR}/intermediate_ca.crt...."
vault_exec read -format=json pki_int/cert/ca > ${WORKDIR}/intermediate_ca.json

jq -r .data.certificate < ${WORKDIR}/intermediate_ca.json > ${WORKDIR}/intermediate_ca.crt


echo "Show the file content of tls.crt: $(cat ${WORKDIR}/tls.crt)"

echo "Show the file content of tls.key: $(cat ${WORKDIR}/tls.key)"

echo "Show the file content of root_ca.crt: $(cat ${WORKDIR}/root_ca.crt)"

echo "Show the file content of intermediate_ca.crt: $(cat ${WORKDIR}/intermediate_ca.crt)"

cat ${WORKDIR}/root_ca.crt ${WORKDIR}/intermediate_ca.crt > ${WORKDIR}/full_ca_chain.pem


echo "Verify that the full chain is correct....."
openssl verify -CAfile ${WORKDIR}/root_ca.crt ${WORKDIR}/intermediate_ca.crt


# Step 3: Create Kubernetes TLS secret
echo "Creating Kubernetes TLS secret..."
kubectl create secret generic $K8S_SECRET_NAME \
    --from-file=tls.crt=${WORKDIR}/tls.crt \
    --from-file=tls.key=${WORKDIR}/tls.key \
    --from-file=ca.crt=${WORKDIR}/full_ca_chain.pem \
    -n $NAMESPACE \
    --context=$CTX_CLUSTER1


# Step 4: Deploy nginx and Istio configurations
echo "Applying nginx and Istio configurations..."

kubectl create configmap nginx-config --from-file=nginx.conf=nginx.conf --context=$CTX_CLUSTER1

# Apply nginx deployment
kubectl apply -f nginx-deploy.yaml  --context=$CTX_CLUSTER1

# Apply nginx service
kubectl apply -f nginx-svc.yaml  --context=$CTX_CLUSTER1

# Apply Istio Gateway
kubectl apply -f nginx-gw.yaml  --context=$CTX_CLUSTER1

# Apply Istio VirtualService
kubectl apply -f nginx-vs.yaml  --context=$CTX_CLUSTER1

kubectl rollout restart deploy -n istio-system --context="$CTX_CLUSTER1" 
kubectl rollout restart deploy -n istio-system --context="$CTX_CLUSTER2"

echo "TLS setup for nginx completed!"

echo "Create a test pod in cluster2...."

kubectl --context="$CTX_CLUSTER2" run curl-pod --image=curlimages/curl --restart=Never --command -- sleep 27600

sleep 5

echo "Copying certificate files to the curl-pod..."
kubectl cp "${WORKDIR}/tls.crt" default/curl-pod:/tmp/tls.crt --context="$CTX_CLUSTER2"
kubectl cp "${WORKDIR}/tls.key" default/curl-pod:/tmp/tls.key --context="$CTX_CLUSTER2"
kubectl cp "${WORKDIR}/full_ca_chain.pem" default/curl-pod:/tmp/full_ca_chain.pem --context="$CTX_CLUSTER2"


# Step 4: Verify the copied files
echo "Verifying copied files in curl-pod..."
kubectl exec -it curl-pod --context="$CTX_CLUSTER2" -- ls -l /tmp/

# Step 5: Provide instructions for testing (Optional)
echo "You can now use curl-pod to test HTTPS or mTLS connections:"
echo "Example command for HTTPS:"
echo "kubectl exec -it curl-pod --context=\"$CTX_CLUSTER2\" -- curl --cacert /tmp/full_ca_chain.pem https://<service-name>:<port>"
echo "Example command for mTLS:"
echo "kubectl exec -it curl-pod --context=\"$CTX_CLUSTER2\" -- curl --cert /tmp/tls.crt --key /tmp/tls.key --cacert /tmp/full_ca_chain.pem https://<service-name>:<port>"