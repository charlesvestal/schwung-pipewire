#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Cleaning build artifacts ==="

rm -rf "$REPO_ROOT/build"
rm -rf "$REPO_ROOT/dist"

echo "Removed build/ and dist/"
echo "Done."
