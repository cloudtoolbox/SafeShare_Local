#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB_PATH="${1:-$ROOT_DIR/SafeShareApp.DB}"

if [ ! -f "$DB_PATH" ]; then
  echo "Database not found: $DB_PATH" >&2
  exit 1
fi

sqlite3 "$DB_PATH" <<'SQL'
.headers on
.mode column
SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;
SELECT code, display_name FROM profiles ORDER BY code;
SELECT code, display_name FROM categories ORDER BY code LIMIT 10;
SQL
