#!/bin/bash

# Function to delete Kind clusters
delete_kind_clusters() {
  echo "Fetching existing Kind clusters..."
  clusters=$(kind get clusters)
  
  if [[ -z "$clusters" ]]; then
    echo "No Kind clusters found to delete."
  else
    for cluster in $clusters; do
      echo "Deleting Kind cluster: $cluster..."
      kind delete cluster --name $cluster
    done
  fi
}

# Function to clean up Docker resources
cleanup_docker() {
  echo "Cleaning up Docker containers and networks used by Kind..."
  
  # Remove stopped containers
  echo "Removing stopped containers..."
  docker container prune -f

  # Remove Kind networks
  echo "Removing Kind-related Docker networks..."
  networks=$(docker network ls | grep "kind" | awk '{print $2}')
  for network in $networks; do
    echo "Removing Docker network: $network..."
    docker network rm $network
  done
  
  # Optional: Remove unused images
  echo "Removing unused Docker images..."
  docker image prune -a -f
}

# Function to clean up Kubernetes contexts
cleanup_kube_config() {
  echo "Cleaning up Kubernetes contexts related to Kind..."
  
  # List all contexts
  contexts=$(kubectl config get-contexts -o name | grep "kind-")
  if [[ -z "$contexts" ]]; then
    echo "No Kind-related Kubernetes contexts found."
  else
    for context in $contexts; do
      echo "Deleting Kubernetes context: $context..."
      kubectl config delete-context $context
    done
  fi
}

# Main Script
echo "Starting Kind cluster cleanup..."

# Step 1: Delete Kind clusters
delete_kind_clusters

# Step 2: Clean up Docker resources
cleanup_docker

# Step 3: Clean up Kubernetes contexts
cleanup_kube_config

echo "Kind cleanup completed successfully!"
