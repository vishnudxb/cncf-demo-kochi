storage "raft" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr = "http://vault-internal.vault.svc.cluster.local:8200"
cluster_addr = "http://vault-internal.vault.svc.cluster.local:8201"
