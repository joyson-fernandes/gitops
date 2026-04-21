# openmemory

ArgoCD-managed Helm chart for [OpenMemory](https://github.com/mem0ai/mem0/tree/main/openmemory) — a shared MCP memory pool for Claude Code, Cursor, and local agents.

## Access

- Dashboard: <https://openmemory.joysontech.com> (local network only, local-CA cert)
- API:       <https://openmemory-api.joysontech.com> (local network only, local-CA cert)
- MCP SSE endpoint (Claude Code + Cursor):
  `https://openmemory-api.joysontech.com/mcp/claude/sse/joyson`

## Secrets

Stored in Vault under `secret/openmemory/`:

| Path | Key | Purpose |
|---|---|---|
| `secret/openmemory/db` | `app_password` | Password for the `openmemory` Postgres user |
| `secret/openmemory/db` | `superuser_password` | `postgres` superuser password — consumed by the bootstrap Job only |
| `secret/openmemory/config` | `openai_api_key` | Empty placeholder; set if you ever want OpenAI fallback |

Synced into namespace `openmemory` by ExternalSecrets (`openmemory-db`, `openmemory-config`).

## Dependencies

- **Postgres** — shared CNPG cluster `prod-db` in the `linkvolt` namespace. A PreSync Job (`db-bootstrap-job`) creates the `openmemory` database + role idempotently on every sync.
- **Ollama** — Mac Studio at `10.0.1.120:11434`. Models `gemma4:26b` (chat) and `nomic-embed-text` (embeddings) must be present.
- **Qdrant** — runs in-namespace as a StatefulSet with a 10Gi ceph-block PVC.

## Rebuilding the images

Upstream `mem0ai/mem0` publishes no container images and ships two quirks that need patching:

1. `api/app/database.py` passes SQLite-specific `check_same_thread=False` to SQLAlchemy unconditionally — breaks when `DATABASE_URL` is Postgres.
2. `api/app/utils/categorization.py` always creates an `openai.OpenAI()` client and calls `api.openai.com/v1/chat/completions` on every memory insert, even when you've configured Ollama. With no `OPENAI_API_KEY`, every insert hangs for ~27s of retries and eventually errors — the memory still goes to Qdrant but not to Postgres.

The `-pg2` image applies both patches.

```bash
# Fetch a clean tree and pin an upstream SHA
cd /tmp && rm -rf mem0
git clone https://github.com/mem0ai/mem0.git && cd mem0
SHA=$(git rev-parse --short HEAD)   # or checkout a specific release
echo "building from $SHA"

# Apply both patches
cd openmemory
python3 - <<'PY'
# Patch 1: Postgres connect_args
p = 'api/app/database.py'
data = open(p).read()
new = data.replace(
    'engine = create_engine(\n    DATABASE_URL,\n    connect_args={"check_same_thread": False}  # Needed for SQLite\n)',
    'connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}\nengine = create_engine(\n    DATABASE_URL,\n    connect_args=connect_args,\n    pool_pre_ping=True\n)'
)
assert new != data, 'patch 1 failed'
open(p, 'w').write(new)

# Patch 2: skip categorization when OPENAI_API_KEY unset
p = 'api/app/utils/categorization.py'
data = open(p).read()
old = '''def get_categories_for_memory(memory: str) -> List[str]:
    try:
        messages = ['''
new = '''def get_categories_for_memory(memory: str) -> List[str]:
    # Skip categorization entirely when no usable OpenAI key is set. mem0 itself
    # supports Ollama but this hardcoded openai_client always calls api.openai.com.
    import os
    if not os.environ.get("OPENAI_API_KEY"):
        return []
    try:
        messages = ['''
assert old in data, 'patch 2 failed'
open(p, 'w').write(data.replace(old, new))
PY

# Build + push both images (amd64 for the K8s cluster)
docker buildx build --platform=linux/amd64 \
  -t registry.joysontech.com/library/openmemory-api:${SHA}-pg2 \
  -f api/Dockerfile api/ --push

docker buildx build --platform=linux/amd64 \
  -t registry.joysontech.com/library/openmemory-ui:${SHA} \
  -f ui/Dockerfile ui/ --push

# Bump image.api.tag / image.ui.tag in values.yaml, commit, ArgoCD syncs.
```

The `-pgN` suffix on the API tag tracks our patch revision; bump `N` if the patch set changes (keep both patches in a single suffix).

## Initial Postgres role + database

The bootstrap Job (Sync hook, wave 1) runs `postgres:17-alpine` and executes:

```sql
CREATE ROLE openmemory LOGIN PASSWORD '<app_password from Vault>';
CREATE DATABASE openmemory OWNER openmemory;
GRANT ALL PRIVILEGES ON DATABASE openmemory TO openmemory;
GRANT ALL ON SCHEMA public TO openmemory;
```

Wrapped in idempotent `IF NOT EXISTS` checks. Superuser password is read from the `openmemory-db` Secret (mirrored from Vault via ExternalSecrets).

## Schema

OpenMemory's API auto-creates its SQLAlchemy tables on startup (`Base.metadata.create_all`). No Alembic migration step is required from the chart.

## Labels

All workloads carry the Kyverno-required set: `app=openmemory`, `tier=app|db`, `team=platform`, `env=production`.
