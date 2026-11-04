#!/usr/bin/env bash
# ==============================================================================
# tests/test_core.sh - Test Core Engine (memory.sh and docker.sh)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> Testing core/memory.sh in dry-run mode..."
"$SCRIPT_DIR/core/memory.sh"

echo ">>> Testing core/docker.sh in dry-run mode..."
"$SCRIPT_DIR/core/docker.sh"

echo "✅ Core Engine tests passed in dry-run mode!"
