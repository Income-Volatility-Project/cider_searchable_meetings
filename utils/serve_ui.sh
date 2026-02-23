#!/usr/bin/env bash
set -e

PORT=${1:-8080}
DIR="$(cd "$(dirname "$0")/../ui" && pwd)"

echo "Serving UI at http://localhost:${PORT}"
python3 -m http.server "$PORT" --directory "$DIR"
