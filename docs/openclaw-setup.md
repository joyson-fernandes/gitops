# OpenClaw Setup Guide

OpenClaw is an open-source autonomous AI agent deployed on the K8s cluster with hardened security. It connects to messaging platforms (Discord, Telegram) and executes tasks via LLMs.

## Architecture

```
K8s Cluster
┌─────────────────────────────────────────────────────┐
│  traefik namespace          openclaw namespace       │
│  ┌──────────┐               ┌─────────────────────┐ │
│  │ Traefik  │──CiliumNP──►  │ OpenClaw Pod        │ │
│  │ :443 TLS │   :18789      │  bind: lan (0.0.0.0)│ │
│  └──────────┘               │  token auth         │ │
│                             │  read-only root FS  │ │
│                             │  drop ALL caps      │ │
│                             │  non-root UID 1000  │ │
│                             └─────────────────────┘ │
│                             ┌──────────┐ ┌────────┐ │
│                             │ PVC 5Gi  │ │ Vault  │ │
│                             │ceph-block│ │ Secret │ │
│                             └──────────┘ └────────┘ │
└─────────────────────────────────────────────────────┘
```

## Access

**URL:** https://openclaw.joysontech.com (local network only, local CA TLS)

**Login:** Open with token hash:
```
https://openclaw.joysontech.com/#token=<gateway-token>
```

**Get the token:**
```bash
kubectl get secret openclaw-gateway -n openclaw -o jsonpath='{.data.token}' | base64 -d
```

**DNS:** `openclaw.joysontech.com` → `10.0.1.25` (local DNS / /etc/hosts)

## Components

| Resource | Location | Purpose |
|----------|----------|---------|
| ArgoCD Application | `gitops/apps/tools/openclaw.yaml` | GitOps entry point |
| Helm Chart | `gitops/charts/openclaw/` | All K8s manifests |
| Values | `gitops/charts/openclaw/values.yaml` | Configuration |
| Vault Secret | `secret/openclaw/gateway` | 64-char gateway token |
| Docker Image | `registry.joysontech.com/library/openclaw:v2026.3.7` | amd64, mirrored from GHCR |

## Key Config: openclaw.json

The init container copies the ConfigMap to `~/.openclaw/openclaw.json` on every pod start. This is the official pattern from the OpenClaw K8s manifests.

```json
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,
    "auth": { "mode": "token" },
    "controlUi": {
      "enabled": true,
      "allowedOrigins": ["https://openclaw.joysontech.com"],
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
```

### Critical settings explained

- **`bind: lan`** — listens on `0.0.0.0`. Must use bind modes (`lan`/`loopback`/`tailnet`/`auto`), NOT raw IPs like `0.0.0.0`.
- **`auth.mode: token`** — must be an object `{"mode":"token"}`, not a string `"token"`.
- **`dangerouslyDisableDeviceAuth: true`** — required for Kubernetes. Device pairing is incompatible with K8s (users can't approve pairing inside a container, connections are always proxied). This is safe because token auth + TLS + local-only middleware still protect access.
- **`allowedOrigins`** — must include the exact origin URL used in the browser.
- **`trustedProxies`** — NOT used. Only accepts exact IPs (no CIDRs), and pod IPs change on restart. Instead, `dangerouslyDisableDeviceAuth` handles the proxy case.

## Security Hardening

### Pod Security
- `readOnlyRootFilesystem: true` — only `~/.openclaw` (PVC) and `/tmp` (emptyDir 100Mi) writable
- `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false`
- `runAsNonRoot: true`, UID/GID 1000 (node user)
- `seccompProfile: RuntimeDefault`
- `automountServiceAccountToken: false`

### Network Policy (CiliumNetworkPolicy)
- **Ingress:** Only Traefik namespace on port 18789
- **Egress:** DNS (kube-dns), Ollama (10.0.1.120:11434), messaging platforms (:443)

### Access Control
- Local CA TLS cert (trusted on Mac via system keychain)
- `local-only` Traefik middleware (10.0.0.0/8 only)
- Token auth (64-char hex from Vault)

## Updating the Image

```bash
# On CI runner (10.0.1.40) — MUST use amd64, cluster is amd64
ssh joyson@10.0.1.40
docker pull --platform linux/amd64 ghcr.io/openclaw/openclaw:latest
docker tag ghcr.io/openclaw/openclaw:latest registry.joysontech.com/library/openclaw:vYYYY.X.X
docker push registry.joysontech.com/library/openclaw:vYYYY.X.X
```

Update `charts/openclaw/values.yaml` with the new tag. ArgoCD auto-syncs.

## Troubleshooting

### "exec format error"
Wrong architecture. Pull with `--platform linux/amd64` on the CI runner (not Mac Studio which is arm64).

### "pairing required"
`dangerouslyDisableDeviceAuth: true` is missing from `controlUi` config. Delete the PVC and restart so the init container writes the correct config.

### "origin not allowed"
Add your URL to `controlUi.allowedOrigins` in the configmap. Delete PVC + restart.

### "Config invalid / Unrecognized keys"
OpenClaw's config schema is strict. Don't add `llm`, `skills`, or other non-standard keys at root level. Follow the official schema.

### Config changes not taking effect
The init container copies the configmap to the PVC. If the PVC already has a config, it gets overwritten on each restart. If ArgoCD hasn't synced the configmap yet, the old config gets copied. Fix: sync ArgoCD first, then delete PVC + pod.

### Gateway binds to 127.0.0.1 despite config
OpenClaw reads `~/.openclaw/openclaw.json`, NOT a mounted configmap path. The init container must copy the config there. Check the init container is working: `kubectl logs <pod> -c setup-config`.
