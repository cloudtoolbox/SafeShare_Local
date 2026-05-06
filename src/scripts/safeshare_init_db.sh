#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB_PATH="${1:-$ROOT_DIR/SafeShareApp.DB}"
SCHEMA_PATH="$ROOT_DIR/SafeShareLocal/Resources/Database/safeshare_schema.sql"
SEED_PATH="$ROOT_DIR/SafeShareLocal/Resources/Database/safeshare_seed.sql"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 not found" >&2
  exit 1
fi

sqlite3 "$DB_PATH" < "$SCHEMA_PATH"
sqlite3 "$DB_PATH" < "$SEED_PATH"

echo "Initialized: $DB_PATH"
sqlite3 "$DB_PATH" "SELECT key, value FROM app_meta ORDER BY key;"
