#!/usr/bin/env bash
# Idempotent bootstrap for the Wanxiang Reader Node.js backend.
# Runs after checkout; safe to re-run against cached/partially prepared state.
set -euo pipefail

cd "$(dirname "$0")/../backend"

# Install dependencies (better-sqlite3 ships prebuilt binaries for Node 18/20/22).
npm install --no-audit --no-fund

# better-sqlite3 opens the DB file eagerly on require(), so the directory must
# exist before init-db/seed. .gitignore excludes backend/data, so create it here.
mkdir -p data

# Create tables + run migrations (CREATE TABLE IF NOT EXISTS -> idempotent).
npm run init-db

# Load the default book sources bundled in backend/seed (bulkUpsert -> idempotent).
npm run seed
