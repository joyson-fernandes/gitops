# gitops

ArgoCD Application manifests for the K8s cluster. Single source of truth for all deployed apps.

## Structure

```
root.yaml                    # App-of-Apps root — ArgoCD discovers all apps/ recursively
apps/
  linkvolt/                  # LinkVolt platform (prod, dev, staging, NATS, Redis)
  monitoring/                # Prometheus, Loki, Promtail, Tempo, Grafana dashboards
  storage/                   # Rook-Ceph operator + cluster, Velero MinIO
  platform/                  # IDP UI, Portfolio, Authentik SSO, Kyverno
  security/                  # Vault, Traefik
  tools/                     # Harbor, OpenClaw
charts/
  openclaw/                  # OpenClaw Helm chart (standalone, not part of any app repo)
```

## Adding a new app

1. Create a YAML file in the appropriate `apps/<category>/` directory
2. Commit and push to `main`
3. ArgoCD auto-discovers via the root app-of-apps

## Bootstrap

Apply the root application to bootstrap the cluster:

```bash
kubectl apply -f root.yaml
```
