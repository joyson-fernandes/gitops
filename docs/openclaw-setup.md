# OpenClaw Setup Guide

OpenClaw is an open-source autonomous AI agent deployed on the K8s cluster with hardened security. It connects to messaging platforms (Discord, Telegram) and executes tasks via Ollama LLM running locally on the Mac Studio.

## Architecture

```
Mac Studio (10.0.1.120)          K8s Cluster
┌──────────────┐                 ┌─────────────────────────────────┐
│ Ollama :11434│◄────────────────│  openclaw namespace             │
│ qwen3.5:27b  │   CiliumPolicy │  ┌───────────────────────────┐  │
└──────────────┘   (egress only) │  │ OpenClaw Pod              │  │
                                 │  │  - read-only root FS      │  │
                                 │  │  - drop ALL capabilities  │  │
                                 │  │  - non-root (UID 1000)    │  │
                                 │  │  - seccomp RuntimeDefault │  │
                                 │  └───────────────────────────┘  │
                                 │  ┌──────────┐ ┌──────────────┐  │
                                 │  │ PVC 5Gi  │ │ Vault Secret │  │
                                 │  │ceph-block│ │gateway token │  │
                                 │  └──────────┘ └──────────────┘  │
                                 └─────────────────────────────────┘
```

## Components

| Resource | Location | Purpose |
|----------|----------|---------|
| ArgoCD Application | `gitops/apps/tools/openclaw.yaml` | GitOps entry point |
| Helm Chart | `gitops/charts/openclaw/` | All K8s manifests |
| Values | `gitops/charts/openclaw/values.yaml` | Configuration |
| Vault Secret | `secret/openclaw/gateway` | 64-char gateway token |
| Docker Image | `registry.joysontech.com/library/openclaw:v2026.3.7` | amd64, mirrored from GHCR |

## Helm Chart Templates

| Template | What it creates |
|----------|----------------|
| `deployment.yaml` | Hardened pod with security contexts |
| `service.yaml` | ClusterIP on port 18789 |
| `pvc.yaml` | 5Gi on ceph-block for `~/.openclaw` state |
| `configmap.yaml` | `openclaw.json` — gateway config, Ollama LLM provider |
| `configmap-soul.yaml` | `SOUL.md` — safety rules for the AI agent |
| `external-secrets.yaml` | Gateway token from Vault via ESO |
| `networkpolicy.yaml` | CiliumNetworkPolicy — Traefik ingress, scoped egress |
| `ingressroute.yaml` | Traefik IngressRoute for `openclaw.joysontech.com` (local only) |

## Security Hardening

### Pod Security
- `readOnlyRootFilesystem: true` — only `/home/node/.openclaw` (PVC) and `/tmp` (emptyDir 100Mi) are writable
- `capabilities.drop: [ALL]` — no Linux capabilities
- `runAsNonRoot: true`, UID/GID 1000 (node user)
- `allowPrivilegeEscalation: false`
- `seccompProfile: RuntimeDefault`
- `automountServiceAccountToken: false` — no K8s API access

### Network Policy (CiliumNetworkPolicy)
- **Ingress:** Only Traefik namespace on port 18789
- **Egress:** DNS (kube-dns), Ollama (10.0.1.120:11434), messaging platforms (discord.com, gateway.discord.gg, api.telegram.org on :443)
- **Namespace default-deny:** Catches any rogue pods

### Secrets
- Gateway token stored in HashiCorp Vault at `secret/openclaw/gateway`
- Synced to K8s via External Secrets Operator (1h refresh)
- No LLM API key needed — Ollama is unauthenticated on local network

### Skills
- `autoInstall: false` — no ClawHub skills installed without explicit approval
- Empty `allowList` — all skills blocked by default

### SOUL.md Safety Rules
- Requires human confirmation for destructive actions
- No unapproved skill execution
- No credential logging
- No data exfiltration

## Configuration

### values.yaml
```yaml
image:
  repository: registry.joysontech.com/library/openclaw
  tag: "v2026.3.7"

gateway:
  port: 18789
  bindAddress: "0.0.0.0"

llm:
  provider: ollama
  baseUrl: "http://10.0.1.120:11434"    # Mac Studio, native API (NOT /v1)

persistence:
  storageClass: ceph-block
  size: 5Gi

egress:
  ollama:
    ip: "10.0.1.120"
    port: "11434"
  messaging:
    - "discord.com"
    - "gateway.discord.gg"
    - "api.telegram.org"
```

### Key Config Decisions
- **Ollama native API** — must use `http://host:11434`, NOT `/v1`. The `/v1` OpenAI-compatible endpoint breaks tool calling.
- **Gateway on 0.0.0.0** — required for `kubectl port-forward` access. CiliumNetworkPolicy restricts actual ingress to Traefik only.
- **ceph-block storage** — provides data durability across node failures for persistent agent state.
- **Harbor registry** — image mirrored from `ghcr.io/openclaw/openclaw` to comply with Kyverno policies (restrict-registry, disallow-latest-tag).

## Access

### Via port-forward (direct)
```bash
kubectl port-forward -n openclaw deploy/openclaw 18789:18789
# Open http://localhost:18789
```

### Via Traefik (local network)
Access `https://openclaw.joysontech.com` (requires DNS A record pointing to 10.0.1.25).

### Gateway Token
```bash
kubectl get secret openclaw-gateway -n openclaw -o jsonpath='{.data.token}' | base64 -d
```

## Updating the Image

When a new OpenClaw version is released:

```bash
# On CI runner (10.0.1.40)
ssh joyson@10.0.1.40

# Pull amd64 image (IMPORTANT: cluster is amd64, Mac Studio is arm64)
docker pull --platform linux/amd64 ghcr.io/openclaw/openclaw:latest
docker tag ghcr.io/openclaw/openclaw:latest registry.joysontech.com/library/openclaw:vYYYY.X.X
docker push registry.joysontech.com/library/openclaw:vYYYY.X.X
```

Then update `charts/openclaw/values.yaml` with the new tag and push to gitops repo. ArgoCD auto-syncs.

## Troubleshooting

### "exec format error"
Wrong architecture. The image was pulled on arm64 (Mac Studio) instead of amd64 (K8s workers). Re-pull with `--platform linux/amd64` on the CI runner.

### "disconnected (1000): no reason" in dashboard
Gateway is binding to `127.0.0.1`. Change `bindAddress` to `0.0.0.0` in values.yaml.

### "ENOENT: mkdir '/home/node/.openclaw'"
PVC mounted at wrong path. The OpenClaw image runs as the `node` user with home at `/home/node`, not `/home/openclaw`.

### PVC Pending
Check `kubectl get storageclass ceph-block` exists and Ceph is `HEALTH_OK`. If Ceph was rebuilt, restart the CSI controller pods in rook-ceph namespace.

### ExternalSecret not syncing
Vault may be sealed. Check `kubectl get pods -n vault` — if `0/1`, unseal all 3 pods. Then restart ESO: `kubectl rollout restart deployment -n external-secrets`.
