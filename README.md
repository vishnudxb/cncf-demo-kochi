# CNCF Kochi

Step 1:

`bash ./install.sh`

Step 2: 


`cd istio && bash ./install.sh`

Step 3: 

```
cd ..

bash ./vault_setup.sh

```

Step 4: 

``` 
bash ./setup_vault_ns_certificates.sh

```


Step 5: 

``` 
bash ./create_ca_k8s_secret.sh

```

```
kubectl create configmap nginx-config --from-file=nginx.conf=nginx.conf --context=kind-cluster1

```