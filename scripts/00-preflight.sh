#!/usr/bin/env bash
# Pre-stages everything for the lab: kind cluster, cert-manager,
# CloudNativePG operator + barman-cloud plugin, custom pg_duckdb operand
# image, RustFS, the Cluster/ObjectStore/Database CRDs, and the sample
# Iceberg table + embeddings. Idempotent -- safe to re-run.
#
# Run this well before you go on stage (see README.md "Known rough edge").
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"

KIND_CLUSTER="lakehouse-day"
IMAGE_TAG="lakehouse-day/postgres-duckdb:17"
export RUSTFS_ACCESS_KEY="${RUSTFS_ACCESS_KEY:-lakehouseday}"
export RUSTFS_SECRET_KEY="${RUSTFS_SECRET_KEY:-lakehouseday-secret}"
export RUSTFS_ENDPOINT="http://localhost:9000"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
log "Checking prerequisites"
for bin in docker kind kubectl curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin" >&2; exit 1; }
done
if ! kubectl cnpg version >/dev/null 2>&1; then
  echo "kubectl-cnpg plugin not found -- install it: https://cloudnative-pg.io/documentation/current/kubectl-plugin/" >&2
  exit 1
fi

if ! command -v duckdb >/dev/null 2>&1; then
  log "Installing duckdb CLI"
  curl -fsSL https://install.duckdb.org | sh
fi
export PATH="$HOME/.duckdb/cli/latest:$PATH"
command -v duckdb >/dev/null 2>&1 || { echo "duckdb CLI install failed" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "Ensuring kind cluster '$KIND_CLUSTER' exists"
if ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  kind create cluster --name "$KIND_CLUSTER"
else
  echo "already exists"
fi
kubectl config use-context "kind-${KIND_CLUSTER}"

# ---------------------------------------------------------------------------
log "Installing cert-manager (required by the barman-cloud plugin webhook)"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --for=condition=Available --timeout=180s -n cert-manager deployment --all

# ---------------------------------------------------------------------------
log "Installing the CloudNativePG operator"
CNPG_RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/cloudnative-pg/cloudnative-pg/releases/latest)"
CNPG_VERSION="$(printf '%s' "$CNPG_RELEASE_JSON" | grep '"tag_name"' | sed -n '1s/.*"v\([0-9.]*\)".*/\1/p')"
kubectl apply --server-side -f "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}/cnpg-${CNPG_VERSION}.yaml"
kubectl wait --for=condition=Available --timeout=180s -n cnpg-system deployment --all

log "Installing the barman-cloud CNPG-I plugin"
BARMAN_RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/cloudnative-pg/plugin-barman-cloud/releases/latest)"
BARMAN_VERSION="$(printf '%s' "$BARMAN_RELEASE_JSON" | grep '"tag_name"' | sed -n '1s/.*"v\([0-9.]*\)".*/\1/p')"
kubectl apply -f "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v${BARMAN_VERSION}/manifest.yaml"
kubectl wait --for=condition=Available --timeout=180s -n cnpg-system deployment --all

# ---------------------------------------------------------------------------
log "Building the custom operand image (CNPG postgres 17 + prebuilt pg_duckdb)"
docker build -t "$IMAGE_TAG" "$REPO_ROOT/image"
kind load docker-image "$IMAGE_TAG" --name "$KIND_CLUSTER"

# ---------------------------------------------------------------------------
log "Creating the rustfs-credentials secret"
kubectl create secret generic rustfs-credentials \
  --from-literal=ACCESS_KEY_ID="$RUSTFS_ACCESS_KEY" \
  --from-literal=ACCESS_SECRET_KEY="$RUSTFS_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Deploying RustFS"
kubectl apply -f "$REPO_ROOT/manifests/01-rustfs.yaml"
kubectl rollout status deployment/rustfs --timeout=180s

log "Deploying ObjectStore, Cluster, Database CRDs"
kubectl apply -f "$REPO_ROOT/manifests/02-objectstore.yaml"
kubectl apply -f "$REPO_ROOT/manifests/03-cluster.yaml"
kubectl apply -f "$REPO_ROOT/manifests/04-database.yaml"

log "Waiting for the pglake Cluster to be healthy (can take a few minutes)"
for _ in $(seq 1 60); do
  phase="$(kubectl get cluster pglake -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "  phase: ${phase:-<none yet>}"
  [[ "$phase" == "Cluster in healthy state" ]] && break
  sleep 5
done
kubectl cnpg status pglake || true

# ---------------------------------------------------------------------------
log "Port-forwarding RustFS to localhost:9000 to create the bucket and load sample data"
kubectl port-forward svc/rustfs 9000:9000 >/tmp/lakehouse-day-portforward.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 3

if command -v aws >/dev/null 2>&1; then
  AWS_ACCESS_KEY_ID="$RUSTFS_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$RUSTFS_SECRET_KEY" \
    aws --endpoint-url "$RUSTFS_ENDPOINT" s3 mb s3://lakehouse 2>/dev/null || echo "bucket already exists"
else
  duckdb -c "
    INSTALL httpfs; LOAD httpfs;
    CREATE SECRET rustfs (TYPE S3, KEY_ID '${RUSTFS_ACCESS_KEY}', SECRET '${RUSTFS_SECRET_KEY}', ENDPOINT 'localhost:9000', URL_STYLE 'path', USE_SSL false, REGION 'us-east-1');
  " >/dev/null
  echo "aws CLI not found -- create the 'lakehouse' bucket via the RustFS console at http://localhost:9001 before continuing" >&2
fi

log "Generating the sample Iceberg table (pattern 1 & 2)"
"$DIR/01-generate-iceberg-table.sh"

log "Generating the sample embeddings (pattern 3)"
"$DIR/02-generate-embeddings.sh"

log "Rendering sql/02-fdw-iceberg.sql"
"$DIR/03-render-sql.sh"

kill "$PF_PID" 2>/dev/null || true
trap - EXIT

log "Pre-flight complete. Follow LAB.md to run through the three patterns."
