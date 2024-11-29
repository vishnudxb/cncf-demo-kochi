#!/bin/bash

CTX_CLUSTER1="kind-cluster1"  # Cluster 1 context
CTX_CLUSTER2="kind-cluster2"  # Cluster 2 context
K8S_SECRET_NAME="nginx-tls-secret"
NAMESPACE="istio-system"
WORKDIR=/tmp/vault4

kubectl delete -f ./ --context=$CTX_CLUSTER1 --ignore-not-found
kubectl delete secret $K8S_SECRET_NAME --context=$CTX_CLUSTER1 -n $NAMESPACE
kubectl delete configmap nginx-config --context=$CTX_CLUSTER1
rm -rvf ${WORKDIR}/*
kubectl --context="$CTX_CLUSTER2" delete pod curl-pod --force || echo "Pod is not running...."
echo "Cleanup completed."