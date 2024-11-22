bash ./install.sh

cd istio && bash ./install.sh

cd ..

bash ./vault_istio_setup.sh


➜  cncf-demo-kochi git:(master) ✗ k exec -it vault-0 --context="$CTX_CLUSTER1" -n vault -- vault status -ca-cert=/vault/tls/tls.crt
Key                Value
---                -----
Seal Type          shamir
Initialized        false
Sealed             true
Total Shares       0
Threshold          0
Unseal Progress    0/0
Unseal Nonce       n/a
Version            1.18.1
Build Date         2024-10-29T14:21:31Z
Storage Type       raft
HA Enabled         true
command terminated with exit code 2