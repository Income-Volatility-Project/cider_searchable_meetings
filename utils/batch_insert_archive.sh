#!/bin/bash

# =============================================================================
# Batch Insert Archive Records from CSV
# =============================================================================
# Usage: ./batch_insert_archive.sh path/to/data.csv
#
# CSV Format (with header row):
# meeting_id,summary,transcript,creation_time
#
# Inserts into: archive(meeting_id, summary BYTEA, transcript BYTEA)
# creation_time is ignored (not in schema)
# =============================================================================

# Configuration — read from env vars, with local-dev defaults
SUPABASE_PROJECT_URL="${SUPABASE_URL:-http://localhost:54321}"
SUPABASE_API_KEY="${SUPABASE_KEY:-sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH}"

API_ENDPOINT="${SUPABASE_PROJECT_URL}/rest/v1/archive"

# =============================================================================

if [ $# -eq 0 ]; then
    echo "Error: No CSV file provided"
    echo "Usage: $0 path/to/data.csv"
    exit 1
fi

CSV_FILE="$1"

if [ ! -f "$CSV_FILE" ]; then
    echo "Error: File '$CSV_FILE' not found"
    exit 1
fi

TOTAL=$(( $(wc -l < "$CSV_FILE" | tr -d ' ') - 1 ))  # subtract header row
echo "Inserting $TOTAL records from $CSV_FILE"
echo "Endpoint: $API_ENDPOINT"
echo ""

SUCCESS=0
FAILED=0
ROW=0
FIRST=1

while IFS=',' read -r meeting_id summary_hex transcript_hex creation_time; do
    # Skip header row
    if [ $FIRST -eq 1 ]; then
        FIRST=0
        continue
    fi

    [ -z "$meeting_id" ] && continue
    ROW=$((ROW + 1))

    RESPONSE=$(curl -s -w "\n%{http_code}" \
        -X POST "$API_ENDPOINT" \
        -H "apikey: $SUPABASE_API_KEY" \
        -H "Authorization: Bearer $SUPABASE_API_KEY" \
        -H "Content-Type: application/json" \
        -H "Prefer: return=minimal" \
        -d "{\"meeting_id\": \"$meeting_id\", \"summary\": \"\\\\x$summary_hex\", \"transcript\": \"\\\\x$transcript_hex\"}")

    HTTP_CODE=$(printf '%s' "$RESPONSE" | tail -1)
    BODY=$(printf '%s' "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" = "201" ]; then
        echo "[$ROW/$TOTAL] OK      $meeting_id"
        SUCCESS=$((SUCCESS + 1))
    elif [ "$HTTP_CODE" = "409" ]; then
        echo "[$ROW/$TOTAL] SKIPPED $meeting_id (already exists)"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "[$ROW/$TOTAL] FAIL    $meeting_id (HTTP $HTTP_CODE) $BODY"
        FAILED=$((FAILED + 1))
    fi
done < "$CSV_FILE"

echo ""
echo "Done: $SUCCESS inserted, $FAILED failed"

[ $FAILED -gt 0 ] && exit 1 || exit 0
