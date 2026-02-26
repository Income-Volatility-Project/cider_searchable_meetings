#!/usr/bin/env bash
# Seed the local Supabase vault with OPENAI_API_KEY after a `supabase db reset`.
#
# Usage:
#   ./utils/seed_local_vault.sh
#
# Reads OPENAI_API_KEY from .env (if present) or the current shell environment.
# Safe to run multiple times — skips if the secret already exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Load .env if it exists
if [[ -f "$ENV_FILE" ]]; then
    # Export only OPENAI_API_KEY to avoid polluting the environment
    OPENAI_API_KEY="$(grep -E '^OPENAI_API_KEY=' "$ENV_FILE" | head -1 | cut -d'"' -f2 | cut -d"'" -f2 | sed 's/^[^=]*=//')"

    DB_URL="$(grep -E '^DB_URL=' "$ENV_FILE" | head -1 | cut -d'"' -f2 | cut -d"'" -f2 | sed 's/^[^=]*=//')"
fi

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "Error: OPENAI_API_KEY is not set (checked .env and environment)." >&2
    exit 1
fi

psql "$DB_URL" <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'OPENAI_API_KEY') THEN
        PERFORM vault.create_secret('${OPENAI_API_KEY}', 'OPENAI_API_KEY');
        RAISE NOTICE 'Vault: OPENAI_API_KEY seeded.';
    ELSE
        RAISE NOTICE 'Vault: OPENAI_API_KEY already present, skipping.';
    END IF;
END;
\$\$;

-- Backfill embeddings for any rows inserted before the vault key was available
-- (e.g. seed.sql runs during `supabase db reset` before this script).
SQL

echo "Done."
