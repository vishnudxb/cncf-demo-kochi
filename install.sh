#!/bin/bash

# Make sure you install kind in your machine. https://kind.sigs.k8s.io/docs/user/quick-start#installation

kind create cluster --name cluster1 --config ./kind-cluster1.yaml || echo "kind-cluster1 is running..."
kind create cluster --name cluster2 --config ./kind-cluster2.yaml || echo "kind-cluster2 is running..."

source ./context.sh

kubectl get nodes --context="$CTX_CLUSTER1"
kubectl get nodes --context="$CTX_CLUSTER2"

# Cluster 1
kubectl --context="$CTX_CLUSTER1" cluster-info dump | grep -E "cluster-cidr|service-cluster-ip-range"

# Cluster 2
kubectl --context="$CTX_CLUSTER2" cluster-info dump | grep -E "cluster-cidr|service-cluster-ip-range"


# Patch kube-proxy ConfigMap to enable strictARP
echo "Patching kube-proxy ConfigMap to enable strictARP..."
kubectl --context "$CTX_CLUSTER1" -n kube-system get configmap kube-proxy -o yaml | \
  sed 's/strictARP: false/strictARP: true/' | \
  kubectl -n kube-system  --context "$CTX_CLUSTER1" apply -f -

kubectl --context "$CTX_CLUSTER2" -n kube-system get configmap kube-proxy -o yaml | \
  sed 's/strictARP: false/strictARP: true/' | \
  kubectl -n kube-system  --context "$CTX_CLUSTER2" apply -f -

# Restart kube-proxy to apply the changes
kubectl --context "$CTX_CLUSTER1" -n kube-system rollout restart daemonset/kube-proxy
kubectl --context "$CTX_CLUSTER2" -n kube-system rollout restart daemonset/kube-proxy

sleep 5

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml  --context="$CTX_CLUSTER1"
sleep 5  # Wait for MetalLB pods to initialize
kubectl apply -f ./metallb-config1.yaml --context="$CTX_CLUSTER1" 

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml  --context="$CTX_CLUSTER2"
sleep 5  # Wait for MetalLB pods to initialize
kubectl apply -f ./metallb-config2.yaml --context="$CTX_CLUSTER2" 

# kubectl delete validatingwebhookconfigurations.admissionregistration.k8s.io metallb-webhook-configuration --context $CTX_CLUSTER1
# kubectl delete validatingwebhookconfigurations.admissionregistration.k8s.io metallb-webhook-configuration --context $CTX_CLUSTER2

echo "Adding static routes..."
CLUSTER1_ROUTES=$(kubectl --context "$CTX_CLUSTER1" get nodes -owide -o=jsonpath='{range .items[*]}{"ip route add "}{.spec.podCIDR}{" via "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
CLUSTER2_ROUTES=$(kubectl --context "$CTX_CLUSTER2" get nodes -owide -o=jsonpath='{range .items[*]}{"ip route add "}{.spec.podCIDR}{" via "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

for NODE in $(kind get nodes --name cluster1); do
  echo "$CLUSTER2_ROUTES" | while read -r ROUTE; do
    docker exec "$NODE" sh -c "$ROUTE"
  done
done

for NODE in $(kind get nodes --name cluster2); do
  echo "$CLUSTER1_ROUTES" | while read -r ROUTE; do
    docker exec "$NODE" sh -c "$ROUTE"
  done
done

# Installing istio on both cluster

curl -L https://istio.io/downloadIstio | sh -
cd istio-*
export PATH=$PWD/bin:$PATH

istioctl version --context="$CTX_CLUSTER1"
istioctl version --context="$CTX_CLUSTER2"