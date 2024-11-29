# CNCF Kochi

Step 1:

```

bash ./install.sh

```

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

cd istio
bash ./install.sh

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


kubectl rollout restart deploy -n istio-system --context="$CTX_CLUSTER1"
kubectl rollout restart deploy -n istio-system --context="$CTX_CLUSTER2"


```


```

kubectl --context="$CTX_CLUSTER1" create deployment nginx --image=nginx

kubectl --context "$CTX_CLUSTER1" expose deployment nginx --type=ClusterIP --port=8080 --target-port=80

kubectl --context="$CTX_CLUSTER1" run curl-pod --image=curlimages/curl --restart=Never --command -- sleep 27600

kubectl exec -it curl-pod --context="$CTX_CLUSTER1" -- curl http://nginx:8080

kubectl delete pod curl-pod --context="$CTX_CLUSTER1" --force

kubectl get pods --context="$CTX_CLUSTER1"

kubectl --context="$CTX_CLUSTER2" run curl-pod --image=curlimages/curl --restart=Never --command -- sleep 27600

kubectl get pods --context="$CTX_CLUSTER2"

kubectl exec -it curl-pod --context="$CTX_CLUSTER2" -- curl http://nginx:8080

istioctl proxy-config cluster curl-pod -n default --context="$CTX_CLUSTER2"

```


```

cd nginx-cluster1
bash ./install.sh


openssl x509 -noout -modulus -in /tmp/vault4/tls.crt | openssl md5
openssl rsa -noout -modulus -in /tmp/vault4/tls.key | openssl md5
openssl verify -CAfile /tmp/vault4/full_ca_chain.pem /tmp/vault4/tls.crt


```


From outside:

```

kubectl rollout restart deploy -n istio-system --context="$CTX_CLUSTER1"
kubectl rollout restart deploy -n istio-system --context="$CTX_CLUSTER2"

➜  cncf-demo-kochi git:(master) ✗ curl -v --resolve ngx-svc-cluster1.default.svc.cluster.local:8080:172.18.0.150 --cacert /tmp/vault4/full_ca_chain.pem https://ngx-svc-cluster1.default.svc.cluster.local:8080
* Added ngx-svc-cluster1.default.svc.cluster.local:8080:172.18.0.150 to DNS cache
* Hostname ngx-svc-cluster1.default.svc.cluster.local was found in DNS cache
*   Trying 172.18.0.150:8080...
* Connected to ngx-svc-cluster1.default.svc.cluster.local (172.18.0.150) port 8080
* ALPN: curl offers h2,http/1.1
* (304) (OUT), TLS handshake, Client hello (1):
*  CAfile: /tmp/vault4/full_ca_chain.pem
*  CApath: none
* (304) (IN), TLS handshake, Server hello (2):
* (304) (IN), TLS handshake, Unknown (8):
* (304) (IN), TLS handshake, Certificate (11):
* (304) (IN), TLS handshake, CERT verify (15):
* (304) (IN), TLS handshake, Finished (20):
* (304) (OUT), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / AEAD-CHACHA20-POLY1305-SHA256 / [blank] / UNDEF
* ALPN: server accepted h2
* Server certificate:
*  subject: CN=ngx-svc-cluster1.default.svc.cluster.local
*  start date: Nov 28 01:08:05 2024 GMT
*  expire date: Nov 29 01:08:35 2024 GMT
*  subjectAltName: host "ngx-svc-cluster1.default.svc.cluster.local" matched cert's "ngx-svc-cluster1.default.svc.cluster.local"
*  issuer: CN=svc.cluster.local Intermediate Authority
*  SSL certificate verify ok.
* using HTTP/2
* [HTTP/2] [1] OPENED stream for https://ngx-svc-cluster1.default.svc.cluster.local:8080/
* [HTTP/2] [1] [:method: GET]
* [HTTP/2] [1] [:scheme: https]
* [HTTP/2] [1] [:authority: ngx-svc-cluster1.default.svc.cluster.local:8080]
* [HTTP/2] [1] [:path: /]
* [HTTP/2] [1] [user-agent: curl/8.7.1]
* [HTTP/2] [1] [accept: */*]
> GET / HTTP/2
> Host: ngx-svc-cluster1.default.svc.cluster.local:8080
> User-Agent: curl/8.7.1
> Accept: */*
>
* Request completely sent off
< HTTP/2 200
< server: istio-envoy
< date: Thu, 28 Nov 2024 01:23:19 GMT
< content-type: text/plain,text/plain
< content-length: 27
< x-envoy-upstream-service-time: 2
<
* Connection #0 to host ngx-svc-cluster1.default.svc.cluster.local left intact
Welcome to Nginx cluster 1!%

```

```

➜  cncf-demo-kochi git:(master) ✗
➜  cncf-demo-kochi git:(master) ✗ kubectl exec -it curl-pod --context="$CTX_CLUSTER2" -- /bin/sh
~ $
~ $ curl -v --resolve ngx-svc-cluster1.default.svc.cluster.local:8080:172.18.0.150 \
>     --cacert /tmp/full_ca_chain.pem https://ngx-svc-cluster1.default.svc.cluster.local:8080
* Added ngx-svc-cluster1.default.svc.cluster.local:8080:172.18.0.150 to DNS cache
* Hostname ngx-svc-cluster1.default.svc.cluster.local was found in DNS cache
*   Trying 172.18.0.150:8080...
* ALPN: curl offers h2,http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
*  CAfile: /tmp/full_ca_chain.pem
*  CApath: /etc/ssl/certs
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* TLSv1.3 (OUT), TLS change cipher, Change cipher spec (1):
* TLSv1.3 (OUT), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / x25519 / RSASSA-PSS
* ALPN: server accepted h2
* Server certificate:
*  subject: CN=ngx-svc-cluster1.default.svc.cluster.local
*  start date: Nov 28 01:08:05 2024 GMT
*  expire date: Nov 29 01:08:35 2024 GMT
*  subjectAltName: host "ngx-svc-cluster1.default.svc.cluster.local" matched cert's "ngx-svc-cluster1.default.svc.cluster.local"
*  issuer: CN=svc.cluster.local Intermediate Authority
*  SSL certificate verify ok.
*   Certificate level 0: Public key type RSA (2048/112 Bits/secBits), signed using sha256WithRSAEncryption
*   Certificate level 1: Public key type RSA (2048/112 Bits/secBits), signed using sha256WithRSAEncryption
* Connected to ngx-svc-cluster1.default.svc.cluster.local (172.18.0.150) port 8080
* using HTTP/2
* [HTTP/2] [1] OPENED stream for https://ngx-svc-cluster1.default.svc.cluster.local:8080/
* [HTTP/2] [1] [:method: GET]
* [HTTP/2] [1] [:scheme: https]
* [HTTP/2] [1] [:authority: ngx-svc-cluster1.default.svc.cluster.local:8080]
* [HTTP/2] [1] [:path: /]
* [HTTP/2] [1] [user-agent: curl/8.11.0]
* [HTTP/2] [1] [accept: */*]
> GET / HTTP/2
> Host: ngx-svc-cluster1.default.svc.cluster.local:8080
> User-Agent: curl/8.11.0
> Accept: */*
>
* Request completely sent off
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
< HTTP/2 200
< server: istio-envoy
< date: Thu, 28 Nov 2024 01:29:25 GMT
< content-type: text/plain,text/plain
< content-length: 27
< x-envoy-upstream-service-time: 1
<
* Connection #0 to host ngx-svc-cluster1.default.svc.cluster.local left intact
Welcome to Nginx cluster 1!~ $

```

```

kubectl exec -it curl-pod  --context="$CTX_CLUSTER2" -- curl http://ngx-svc-cluster1.default.svc.cluster.local:8080

```