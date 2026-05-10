# gateway-api-crds

Single source of truth for the Kubernetes Gateway API CRDs in this cluster.

## Why this exists

Cilium 1.19.x hard-codes `gateway.networking.k8s.io/v1alpha2 TLSRoute` as a
required field indexer in the operator. Upstream Gateway API v1.5.x marks
`v1alpha2` as `served=false, deprecated=true`. Without v1alpha2 served the
cilium-operator crashes at startup with:

```
failed to setup field indexer "backendServiceTLSRouteIndex":
  no matches for kind "TLSRoute" in version "gateway.networking.k8s.io/v1alpha2"
```

Multiple Helm charts (Traefik v40+, Cilium itself, etc.) ship gateway-api
CRDs in their `crds/` directory, fight each other for SSA ownership, and
will silently drag the cluster onto whatever bundle they happen to pin.

This app pins the CRDs to a single known-good version with the TLSRoute
v1alpha2 served-flag patched back on. Every other chart that bundles
gateway-api CRDs MUST set `helm.skipCrds: true`.

## Source

`standard-install-v1.5.1.yaml` is the upstream
`https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml`
manifest with one local patch:

```yaml
# tlsroutes.gateway.networking.k8s.io
spec:
  versions:
    - name: v1alpha2
      served: true   # patched: upstream ships served=false (deprecated)
```

## When to bump

Once Cilium 1.20+ is GA and rolled out to this cluster, the upstream
PR https://github.com/cilium/cilium/pull/45825 drops the v1alpha2
TLSRoute hardcoding. At that point:

1. Replace `standard-install-v1.5.1.yaml` with an unmodified upstream release
2. Drop the v1alpha2 patch
3. Eventually consider deleting the v1alpha2 served entry entirely

Tracking issue: https://github.com/cilium/cilium/issues/44920

## Renovate

Excluded from auto-updates — this file is hand-curated and only bumped
deliberately when Cilium catches up.
