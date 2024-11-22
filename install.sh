#!/bin/bash

# Make sure you install kind in your machine. https://kind.sigs.k8s.io/docs/user/quick-start#installation

kind create cluster --name cluster1 --config kind-cluster1.yaml || echo "Cluster1 is running..."
kind create cluster --name cluster2 --config kind-cluster2.yaml || echo "Cluster1 is running..."

source ./context.sh

kubectl get nodes --context="$CTX_CLUSTER1"
kubectl get nodes --context="$CTX_CLUSTER2"

# Cluster 1
kubectl --context="$CTX_CLUSTER1" cluster-info dump | grep -E "cluster-cidr|service-cluster-ip-range"

# Cluster 2
kubectl --context="$CTX_CLUSTER2" cluster-info dump | grep -E "cluster-cidr|service-cluster-ip-range"


# Installing istio on both cluster

curl -L https://istio.io/downloadIstio | sh -
cd istio-*
export PATH=$PWD/bin:$PATH

istioctl version --context="$CTX_CLUSTER1"
istioctl version --context="$CTX_CLUSTER2"


kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/main/manifests/metallb-native.yaml  --context="$CTX_CLUSTER1"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/main/manifests/metallb-native.yaml  --context="$CTX_CLUSTER2"

kubectl --context="$CTX_CLUSTER1" -f metallb-config1.yaml
kubectl --context="$CTX_CLUSTER2" -f metallb-config2.yaml

