bash ./install.sh

kubectl --context $CTX_CLUSTER2 get nodes -owide -o=jsonpath='{range .items[*]}{"ip route add "}{.spec.podCIDR}{" via "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'

ip route add 10.220.0.0/24 via 172.18.0.5
ip route add 10.220.1.0/24 via 172.18.0.4


kubectl --context $CTX_CLUSTER1 get nodes -owide -o=jsonpath='{range .items[*]}{"ip route add "}{.spec.podCIDR}{" via "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'

ip route add 10.110.0.0/24 via 172.18.0.3
ip route add 10.110.1.0/24 via 172.18.0.2


Add Routes for Cluster 1 on Cluster 2 Nodes:

docker exec cluster2-control-plane ip route add 10.110.0.0/24 via 172.18.0.3
docker exec cluster2-control-plane ip route add 10.110.1.0/24 via 172.18.0.2
docker exec cluster2-worker ip route add 10.110.0.0/24 via 172.18.0.3
docker exec cluster2-worker ip route add 10.110.1.0/24 via 172.18.0.2

Add Routes for Cluster 2 on Cluster 1 Nodes:

docker exec cluster1-control-plane ip route add 10.220.0.0/24 via 172.18.0.5
docker exec cluster1-control-plane ip route add 10.220.1.0/24 via 172.18.0.4
docker exec cluster1-worker ip route add 10.220.0.0/24 via 172.18.0.5
docker exec cluster1-worker ip route add 10.220.1.0/24 via 172.18.0.4

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


kubectl -n vault exec vault-0 --context="$CTX_CLUSTER1" -- cat /vault/tls/..data/tls.crt > ~/cncf-demo-kochi/vault-ca.crt

openssl x509 -in ~/cncf-demo-kochi/vault-ca.crt -out ~/cncf-demo-kochi/vault-ca.pem -outform PEM

sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/cncf-demo-kochi/vault-ca.pem

sudo security delete-certificate -c "vault.vault.svc.cluster.local" /Library/Keychains/System.keychain

bash ./vault_ingress_gateway_setup.sh