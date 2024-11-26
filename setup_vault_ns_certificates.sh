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
WORKDIR=/tmp/vault2
INTERMEDIATE_CA_TTL="43800h"  # 5 years
ROOT_CA_TTL="87600h"          # 10 years
CERT_TTL="24h"
NAMESPACES=("istio-system" "default" "vault") # Namespaces to issue certificates for

mkdir -p $WORKDIR

# Cleanup Function
cleanup() {
    echo "Starting cleanup process..."

    # Delete Intermediate PKI Engine
    echo "Deleting root PKI engine..."
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
        vault secrets disable pki_root || echo "Intermediate PKI engine already removed."

    # Delete Root PKI Engine
    echo "Deleting root PKI engine..."
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
        vault secrets disable pki || echo "Root PKI engine already removed."

    echo "Deleting root PKI engine..."
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
        vault secrets disable pki_intermediate || echo "Root pki_intermediate engine already removed."

    echo "Deleting root PKI engine..."
    kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- \
        vault secrets disable pki_int || echo "Root pki_int engine already removed."

    # Remove temporary files
    echo "Cleaning up temporary files..."
    rm -rvf cncfcaroot-2024.crt cncf_intermediate_csr.json /tmp/cncf_intermediate.csr /tmp/cncfintermediate.cert.pem cncfintermediate_cert.json $WORKDIR/*
    cp -rvf /tmp/vault/cluster-keys.json ${WORKDIR}/cluster-keys.json
    echo "Temporary files removed."

    # Apply the wildcard certificate to the istio-system namespace in both clusters
    for CTX in $CTX_CLUSTER1 $CTX_CLUSTER2; do
        echo "delete cert..."

        kubectl delete secret cacerts default-wildcard-credential vault-wildcard-credential -n istio-system --context=$CTX --ignore-not-found   

        kubectl delete secret istio-reader-service-account-istio-remote-secret-token istio-remote-secret-cluster1 istio-remote-secret-cluster2 -n istio-system --context=$CTX --ignore-not-found     

        echo "Wildcard certificate applied to istio-system in $CTX."
    done

    echo "Cleanup completed."
}

cleanup
echo "Waiting for the clenup..."
sleep 15

echo "Login to vault"
ROOT_TOKEN=$(jq -r '.root_token' ${WORKDIR}/cluster-keys.json)

# Login to Vault
kubectl exec -it $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault login $ROOT_TOKEN

echo "Initializing Vault-based PKI setup..."

# Function to execute Vault commands via kubectl exec
vault_exec() {
  kubectl exec -it  $VAULT_POD -n $VAULT_NAMESPACE --context $VAULT_CLUSTER_CONTEXT -- vault "$@"
}

vault_exec secrets enable pki

vault_exec secrets tune -max-lease-ttl=87600h pki

vault_exec write -field=certificate pki/root/generate/internal \
     common_name="svc.cluster.local" \
     issuer_name="root-2023" \
     ttl=87600h > $WORKDIR/root_2023_ca.crt

vault_exec list pki/issuers/

vault_exec read pki/issuer/$(vault_exec list -format=json pki/issuers/ | jq -r '.[]') | tail -n 6

vault_exec write pki/roles/2023-servers allow_any_name=true

vault_exec write pki/config/urls \
     issuing_certificates="$VAULT_ADDR/v1/pki/ca" \
     crl_distribution_points="$VAULT_ADDR/v1/pki/crl"


vault_exec secrets enable -path=pki_int pki

vault_exec secrets tune -max-lease-ttl=43800h pki_int


vault_exec write -format=json pki_int/intermediate/generate/exported \
     common_name="svc.cluster.local Intermediate Authority" \
     issuer_name="svc-cluster-local-intermediate" \
     ttl="43800h" \
     key_type="rsa" \
     key_bits="2048" > "$WORKDIR/intermediate_csr.json"     

jq -r '.data.private_key' "$WORKDIR/intermediate_csr.json" > "$WORKDIR/ca-key.pem"

jq -r '.data.csr' "$WORKDIR/intermediate_csr.json" > $WORKDIR/pki_intermediate.csr


echo "Copy the file pki_intermediate.csr"
kubectl cp $WORKDIR/pki_intermediate.csr $VAULT_NAMESPACE/$VAULT_POD:/tmp/pki_intermediate.csr --context=$VAULT_CLUSTER_CONTEXT


vault_exec write -format=json pki/root/sign-intermediate \
     issuer_ref="root-2023" \
     csr=@/tmp/pki_intermediate.csr \
     format=pem_bundle ttl="43800h"  > $WORKDIR/intermediate_cert.json


echo "Show private key:....."
cat $WORKDIR/ca-key.pem

jq -r '.data.certificate' "$WORKDIR/intermediate_cert.json" > "$WORKDIR/intermediate.cert.pem"
echo "Show intermediate cert..."
cat $WORKDIR/intermediate.cert.pem

echo "Copy the file intermediate.cert.pem"
kubectl cp $WORKDIR/intermediate.cert.pem $VAULT_NAMESPACE/$VAULT_POD:/tmp/intermediate.cert.pem --context=$VAULT_CLUSTER_CONTEXT

vault_exec write pki_int/intermediate/set-signed certificate=@/tmp/intermediate.cert.pem

echo "read issuers....pki_int/config/issuers"
vault_exec read -field=default pki_int/config/issuers

ISSUER_REF=$(vault_exec read -field=default pki_int/config/issuers)

echo "Issuer ref is: $ISSUER_REF"

vault_exec write pki_int/roles/istio-system-svc-cluster-local \
    issuer_name="svc-cluster-local-intermediate" \
    allow_subdomains=true \
    allow_any_name=true \
    allow_wildcard_certificates=true \
    allow_ip_sans=true \
    allow_localhost=true \
    max_ttl="720h"

echo "Issue certificate for istio-system.svc.cluster.local"
vault_exec write pki_int/issue/istio-system-svc-cluster-local common_name="istio-system.svc.cluster.local" ttl="24h"