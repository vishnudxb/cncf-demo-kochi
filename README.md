# CNCF Kochi

Step 1:

`bash ./install.sh`

Step 2: 

```
cd ..

bash ./vault_setup.sh

```

Step 3: 

``` 
bash ./setup_vault_ns_certificates.sh

```

Step 4: 


```

cd istio && bash ./install.sh

```


Step 5: 

``` 
bash ./create_ca_k8s_secret.sh

```

Step 6: Enable Endpoint Discovery
```

istioctl create-remote-secret \
    --context="$CTX_CLUSTER1" \
    --name=cluster1 \
    --server=https://cluster1-control-plane:6443 | \
    kubectl apply -f - --context="$CTX_CLUSTER2"

istioctl create-remote-secret \
    --context="$CTX_CLUSTER2" \
    --name=cluster2 \
    --server=https://cluster2-control-plane:6443 | \
    kubectl apply -f - --context="$CTX_CLUSTER1"

```


```

kubectl --context="$CTX_CLUSTER1" create deployment nginx --image=nginx

kubectl --context "$CTX_CLUSTER1" expose deployment nginx --type=ClusterIP --port=8080 --target-port=80

kubectl --context="$CTX_CLUSTER1" run curl-pod --image=curlimages/curl --restart=Never --command -- sleep 27600

kubectl exec -it curl-pod --context="$CTX_CLUSTER1" -- curl http://nginx:8080

kubectl --context="$CTX_CLUSTER2" run curl-pod --image=curlimages/curl --restart=Never --command -- sleep 27600

kubectl get pods --context="$CTX_CLUSTER2"

kubectl exec -it curl-pod --context="$CTX_CLUSTER2" -- curl http://nginx:8080

istioctl proxy-config cluster curl-pod -n default --context="$CTX_CLUSTER2"

```