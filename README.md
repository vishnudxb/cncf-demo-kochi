# CNCF Kochi

Step 1:

`bash ./install.sh`

Step 2: 


`cd istio && bash ./install.sh`

Step 3: 

```
cd ..

bash ./vault_istio_setup.sh

```

Step 4: 

``` 
export VAULT_ROOT_TOKEN=<your-root-token>

bash ./vault_ingress_gateway_setup.sh

```

- Manually Join vault-1 and vault-2 to the Raft Cluster (Incase the script failed ;) )

```

export ROOT_TOKEN=$(jq -r '.root_token' vault-init.json)

kubectl exec -it vault-0 --context "$CTX_CLUSTER1" -n vault -- \
  vault login -ca-cert=/vault/tls/tls.crt $ROOT_TOKEN

kubectl exec -it vault-0 --context="$CTX_CLUSTER1" -n vault -- \
vault operator raft list-peers -ca-cert=/vault/tls/tls.crt

kubectl exec -it vault-0 --context="$CTX_CLUSTER1" -n vault  -- \
  vault operator raft join  -leader-ca-cert=@/vault/tls/tls.crt http://vault-1.vault-internal:8200


kubectl exec -it vault-0 --context="$CTX_CLUSTER1" -n vault -- \
  vault operator raft join -leader-ca-cert=/vault/tls/tls.crt http://vault-2.vault-internal:8200 



```

# kubectl -n vault exec vault-0 --context="$CTX_CLUSTER1" -- cat /vault/tls/..data/tls.crt > ~/cncf-demo-kochi/vault-ca.crt

# openssl x509 -in ~/cncf-demo-kochi/vault-ca.crt -out ~/cncf-demo-kochi/vault-ca.pem -outform PEM

# sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/cncf-demo-kochi/vault-ca.pem

# sudo security delete-certificate -c "vault.vault.svc.cluster.local" /Library/Keychains/System.keychain
