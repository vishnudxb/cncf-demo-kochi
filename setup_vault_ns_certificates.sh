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

    # Remove temporary files
    echo "Cleaning up temporary files..."
    rm -rvf cncfcaroot-2024.crt cncf_intermediate_csr.json /tmp/cncf_intermediate.csr /tmp/cncfintermediate.cert.pem cncfintermediate_cert.json $WORKDIR/intermediate_csr.json $WORKDIR/intermediate.csr $WORKDIR/intermediate_cert.pem
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


# Initialize Vault PKI setup
echo "Initializing Vault-based PKI setup inside Kubernetes..."

# Enable Root PKI
echo "Enabling Root PKI in Vault..."
vault_exec secrets enable -path=pki_root pki || echo "Root PKI already enabled."
vault_exec secrets tune -max-lease-ttl=$ROOT_CA_TTL pki_root

echo "Generating Root CA..."
vault_exec write -field=certificate pki_root/root/generate/internal \
    common_name="Root CA for $DOMAIN" \
    ttl=$ROOT_CA_TTL > $WORKDIR/root-cert.pem

vault_exec write pki_root/config/urls \
    issuing_certificates="https://vault.vault.svc.cluster.local:8200/v1/pki_root/ca" \
    crl_distribution_points="https://vault.vault.svc.cluster.local:8200/v1/pki_root/crl"

echo "Root CA generated and configured."

# Create Intermediate CA
echo "Setting up Intermediate PKI..."
vault_exec secrets enable -path=pki_intermediate pki || echo "Intermediate PKI already enabled."
vault_exec secrets tune -max-lease-ttl=$INTERMEDIATE_CA_TTL pki_intermediate

echo "Generating CSR for Intermediate CA..."
vault_exec write -format=json pki_intermediate/intermediate/generate/internal \
    common_name="Intermediate CA for $DOMAIN" \
    ttl=$INTERMEDIATE_CA_TTL > $WORKDIR/intermediate_csr.json

# Verify that the signed certificate is valid
if [[ ! -s $WORKDIR/intermediate_csr.json ]]; then
    echo "Error: Intermediate certificate signing failed. Please check Vault logs."
    exit 1
else 
    echo "show the content of $WORKDIR/intermediate_csr.json.."
    cat $WORKDIR/intermediate_csr.json
fi

jq -r '.data.csr' $WORKDIR/intermediate_csr.json > $WORKDIR/intermediate.csr

echo "showing the content of $WORKDIR/intermediate.csr"

echo "Signing Intermediate CA with Root CA..."

# Sign Intermediate Certificate
echo "Copy the file $WORKDIR/intermediate.csr"
kubectl cp $WORKDIR/intermediate.csr $VAULT_NAMESPACE/$VAULT_POD:/tmp/intermediate.csr --context=$VAULT_CLUSTER_CONTEXT

vault_exec write -format=json pki_root/root/sign-intermediate \
    csr=@/tmp/intermediate.csr \
    format=pem_bundle ttl=$INTERMEDIATE_CA_TTL > $WORKDIR/intermediate_cert.json

jq -r '.data.certificate' $WORKDIR/intermediate_cert.json > $WORKDIR/intermediate_cert.pem


if [[ ! -s $WORKDIR/intermediate_cert.pem ]]; then
    echo "Error: Pem file not created."
    exit 1
else 
    echo "show the content of $WORKDIR/intermediate_cert.pem file....."
    cat $WORKDIR/intermediate_cert.pem
fi

echo "Copy the file $WORKDIR/intermediate_cert.pem"
kubectl cp  $WORKDIR/intermediate_cert.pem $VAULT_NAMESPACE/$VAULT_POD:/tmp/intermediate_cert.pem --context=$VAULT_CLUSTER_CONTEXT


echo "Run set-signed....."
vault_exec write pki_intermediate/intermediate/set-signed certificate=@/tmp/intermediate_cert.pem
        
# Not use in production allow_any_name=true \

echo "Configuring roles for wildcard certificates in namespaces..."
for NAMESPACE in "${NAMESPACES[@]}"; do
    vault_exec write pki_intermediate/roles/$NAMESPACE-wildcard \
        allow_subdomains=true \
        allow_any_name=true \
        allow_wildcard_certificates=true \
        allow_ip_sans=true \
        allow_localhost=true \
        max_ttl=$CERT_TTL
done


echo "Issuing wildcard certificates for namespaces and distributing to clusters..."
for NAMESPACE in "${NAMESPACES[@]}"; do
    vault_exec write -format=json pki_intermediate/issue/$NAMESPACE-wildcard \
        common_name="*.${NAMESPACE}.$DOMAIN" \
        ttl=$CERT_TTL > $WORKDIR/${NAMESPACE}_wildcard_cert.json

    jq -r '.data.certificate' $WORKDIR/${NAMESPACE}_wildcard_cert.json > $WORKDIR/${NAMESPACE}_wildcard_ca-cert.pem
    jq -r '.data.private_key' $WORKDIR/${NAMESPACE}_wildcard_cert.json > $WORKDIR/${NAMESPACE}_wildcard_ca-key.pem
    jq -r '.data.issuing_ca' $WORKDIR/${NAMESPACE}_wildcard_cert.json > $WORKDIR/${NAMESPACE}_wildcard_cert-chain.pem
    
    echo "$(cat $WORKDIR/root-cert.pem)" >> $WORKDIR/${NAMESPACE}_wildcard_cert-chain.pem
done

# Apply the wildcard certificate to the istio-system namespace in both clusters
for CTX in $CTX_CLUSTER1 $CTX_CLUSTER2; do
    echo "Applying wildcard certificate to istio-system namespace in $CTX..."

    kubectl create secret generic cacerts -n istio-system \
        --from-file=ca-cert.pem=$WORKDIR/istio-system_wildcard_ca-cert.pem \
        --from-file=ca-key.pem=$WORKDIR/istio-system_wildcard_ca-key.pem \
        --from-file=cert-chain.pem=$WORKDIR/istio-system_wildcard_cert-chain.pem \
        --from-file=root-cert.pem=$WORKDIR/root-cert.pem \
        --context=$CTX

    echo "Wildcard certificate applied to istio-system in $CTX."
done

# Apply TLS Secrets for Other Namespaces
for CTX in $CTX_CLUSTER1 $CTX_CLUSTER2; do
    for NAMESPACE in "${NAMESPACES[@]:1}"; do
        echo "Applying TLS secret for *.${NAMESPACE}.$DOMAIN in $CTX..."
        kubectl create secret tls ${NAMESPACE}-wildcard-credential \
            --cert=$WORKDIR/${NAMESPACE}_wildcard_ca-cert.pem \
            --key=$WORKDIR/${NAMESPACE}_wildcard_ca-key.pem \
            -n istio-system --context=$CTX
    done
done
