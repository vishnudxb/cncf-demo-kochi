#!/bin/bash

# Make sure you install kind in your machine. https://kind.sigs.k8s.io/docs/user/quick-start#installation

kind create cluster --name cluster1 || echo "Cluster1 is running..."
kind create cluster --name cluster2 || echo "Cluster1 is running..."

source ./context.sh

kubectl get nodes --context="$CTX_CLUSTER1"
kubectl get nodes --context="$CTX_CLUSTER2"

# Installing istio on both cluster

curl -L https://istio.io/downloadIstio | sh -
cd istio-*
export PATH=$PWD/bin:$PATH

istioctl version --context="$CTX_CLUSTER1"
istioctl version --context="$CTX_CLUSTER2"


kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/main/manifests/metallb-native.yaml  --context="$CTX_CLUSTER1"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/main/manifests/metallb-native.yaml  --context="$CTX_CLUSTER2"

