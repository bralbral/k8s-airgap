# External PostgreSQL for Grafana

Grafana can keep its own state in an external PostgreSQL database. This covers
Grafana users, organisations, dashboards, alert rules and settings. It does
not store Prometheus metrics; those continue to be handled by Prometheus and
Thanos/MinIO.

The PostgreSQL service must be reachable from the cluster nodes/pods on TCP
`5432`. Create a dedicated database and a least-privilege role for Grafana.
Use TLS with a CA trusted by the Grafana container where the PostgreSQL service
requires it.

Before installing `kube-prometheus-stack`, create the Secret in the same
namespace as that Helm release (for example, `monitoring`). Do not commit this
Secret or its values.

```bash
kubectl -n monitoring create secret generic grafana-postgresql \
  --from-literal=GF_DATABASE_TYPE=postgres \
  --from-literal=GF_DATABASE_HOST=postgres.internal:5432 \
  --from-literal=GF_DATABASE_NAME=grafana \
  --from-literal=GF_DATABASE_USER=grafana \
  --from-literal=GF_DATABASE_PASSWORD='REPLACE_ME' \
  --from-literal=GF_DATABASE_SSL_MODE=require
```

The monitoring chart download/render stage is not implemented by this scaffold
yet. When that stage is added, install its pinned chart with the supplied
values file:

```bash
helm upgrade --install monitoring \
  charts/kube-prometheus-stack-75.15.0.tgz \
  --namespace monitoring --create-namespace \
  --values charts/values/kube-prometheus-stack.yaml
```

For verified PostgreSQL TLS, mount the CA using the Grafana chart's
`extraConfigmapMounts` option and change `GF_DATABASE_SSL_MODE` to
`verify-ca` or `verify-full`.
