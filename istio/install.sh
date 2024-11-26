#!/bin/bash

# Step 1: Install Istio on Cluster 1
echo "Installing Istio on Cluster 1 ("$CTX_CLUSTER1")..."
yes | istioctl install --context "$CTX_CLUSTER1" -f cluster1.yaml

kubectl label namespace default istio-injection=enabled --context "$CTX_CLUSTER1"

kubectl --context="$CTX_CLUSTER1" get namespace istio-system
kubectl --context="$CTX_CLUSTER1" label namespace istio-system topology.istio.io/network=network1


# Step 3: Install Istio on Cluster 2
echo "Installing Istio on Cluster 2 ("$CTX_CLUSTER2")..."
yes | istioctl install --context "$CTX_CLUSTER2" -f cluster2.yaml
kubectl label namespace default istio-injection=enabled --context "$CTX_CLUSTER2"

kubectl --context="$CTX_CLUSTER2" get namespace istio-system
kubectl --context="$CTX_CLUSTER2" label namespace istio-system topology.istio.io/network=network2

# Step 4: Verify Istio Installation
echo "Verifying Istio installation..."
kubectl get pods -n istio-system --context "$CTX_CLUSTER1"
kubectl get pods -n istio-system --context "$CTX_CLUSTER2"

kubectl get svc  -n istio-system --context "$CTX_CLUSTER1"
kubectl get svc  -n istio-system --context "$CTX_CLUSTER2"

# Step 5: deploy gateway on both clusters

kubectl apply -f ./cross-network-gateway.yaml -n istio-system --context "$CTX_CLUSTER1"
kubectl apply -f ./cross-network-gateway.yaml -n istio-system --context "$CTX_CLUSTER2"

# Step 6: deploy peer authentications on both clusters

kubectl apply -f ./pa.yaml  --context "$CTX_CLUSTER1"
kubectl apply -f ./pa.yaml  --context "$CTX_CLUSTER2"