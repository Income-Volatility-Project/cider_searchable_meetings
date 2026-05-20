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

# Configuration — read from env vars, with local-dev defaults.
# API_URL/POSTGREST_URL may point either at the service root or directly at /rest/v1.
API_BASE_URL="${API_URL:-${POSTGREST_URL:-${SUPABASE_URL:-http://localhost:8787}}}"

API_BASE_URL="${API_BASE_URL%/}"
if [[ "$API_BASE_URL" == */rest/v1 ]]; then
    API_ENDPOINT="${API_BASE_URL}/archive"
else
    API_ENDPOINT="${API_BASE_URL}/rest/v1/archive"
fi

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

    CURL_ARGS=(
        -s -w "\n%{http_code}"
        -X POST "$API_ENDPOINT"
        -H "Content-Type: application/json"
        -H "Prefer: return=minimal"
        -d "{\"meeting_id\": \"$meeting_id\", \"summary\": \"\\\\x$summary_hex\", \"transcript\": \"\\\\x$transcript_hex\"}"
    )

    RESPONSE=$(curl "${CURL_ARGS[@]}")

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
