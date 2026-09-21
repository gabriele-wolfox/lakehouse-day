#!/usr/bin/env bash
# Tears down the kind cluster created by scripts/00-preflight.sh.
set -euo pipefail

KIND_CLUSTER="lakehouse-day"

if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  kind delete cluster --name "$KIND_CLUSTER"
else
  echo "No kind cluster named '$KIND_CLUSTER' found."
fi
