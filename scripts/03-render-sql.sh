#!/usr/bin/env bash
# Fills in sql/02-fdw-iceberg.sql.tmpl with the real Iceberg metadata
# location and RustFS credentials, so the copy/paste in LAB.md has no
# placeholders left in it.
set -euo pipefail

: "${RUSTFS_ACCESS_KEY:?set RUSTFS_ACCESS_KEY}"
: "${RUSTFS_SECRET_KEY:?set RUSTFS_SECRET_KEY}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
METADATA_LOCATION_FILE="$DIR/.iceberg_metadata_location"

if [[ ! -f "$METADATA_LOCATION_FILE" ]]; then
  echo "Run scripts/01-generate-iceberg-table.sh first." >&2
  exit 1
fi

METADATA_LOCATION="$(cat "$METADATA_LOCATION_FILE")"

sed \
  -e "s|__METADATA_LOCATION__|${METADATA_LOCATION}|g" \
  -e "s|__RUSTFS_ACCESS_KEY__|${RUSTFS_ACCESS_KEY}|g" \
  -e "s|__RUSTFS_SECRET_KEY__|${RUSTFS_SECRET_KEY}|g" \
  "$REPO_ROOT/sql/02-fdw-iceberg.sql.tmpl" > "$REPO_ROOT/sql/02-fdw-iceberg.sql"

echo "Rendered sql/02-fdw-iceberg.sql (METADATA_LOCATION=${METADATA_LOCATION})"
