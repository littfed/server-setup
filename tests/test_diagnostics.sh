#!/usr/bin/env bash
# ==============================================================================
# tests/test_diagnostics.sh - Deep Verification of Pre-Flight & Benchmark Modules
# Tests: core/preflight.sh, modules/diagnostics/bench.sh, and setup.sh --bench
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1

echo ">>> [1/6] Syntax checks for preflight and benchmark scripts..."
bash -n "$SCRIPT_DIR/core/preflight.sh"
bash -n "$SCRIPT_DIR/modules/diagnostics/bench.sh"
echo "Syntax checks passed ✅"

echo ">>> [2/6] Testing --help flags..."
"$SCRIPT_DIR/core/preflight.sh" --help >/dev/null
"$SCRIPT_DIR/modules/diagnostics/bench.sh" --help >/dev/null
echo "Help flags work ✅"

echo ">>> [3/6] Testing core/preflight.sh execution and JSON schema..."
pre_out="$("$SCRIPT_DIR/core/preflight.sh")"
echo "$pre_out" | grep -q "Pre-Flight Host Diagnostics" || {
    echo "❌ Missing preflight header in output"; exit 1;
}
echo "$pre_out" | grep -q "Virtualization:" || {
    echo "❌ Missing virtualization info"; exit 1;
}

json_pre="$("$SCRIPT_DIR/core/preflight.sh" --json)"
echo "$json_pre" | jq -e '.status' >/dev/null || {
    echo "❌ Invalid JSON emitted by preflight.sh --json"; exit 1;
}
echo "$json_pre" | jq -e '.resources.available_disk_mb' >/dev/null || {
    echo "❌ Missing disk space in preflight JSON"; exit 1;
}
echo "core/preflight.sh passed ✅"

echo ">>> [4/6] Testing modules/diagnostics/bench.sh dry-run and JSON schema..."
bench_out="$("$SCRIPT_DIR/modules/diagnostics/bench.sh" --dry-run)"
echo "$bench_out" | grep -q "SYSTEM SPECIFICATIONS" || {
    echo "❌ Missing system specs header in bench output"; exit 1;
}
echo "$bench_out" | grep -q "CPU Steal Time" || {
    echo "❌ Missing CPU steal time in bench output"; exit 1;
}
echo "$bench_out" | grep -q "STORAGE I/O PERFORMANCE" || {
    echo "❌ Missing storage section in bench output"; exit 1;
}
echo "$bench_out" | grep -q "NETWORK LATENCY & BANDWIDTH" || {
    echo "❌ Missing network section in bench output"; exit 1;
}

bench_json="$("$SCRIPT_DIR/modules/diagnostics/bench.sh" --dry-run --json)"
echo "$bench_json" | jq -e '.cpu_benchmark.steal_time_pct' >/dev/null || {
    echo "❌ Invalid JSON emitted by bench.sh --json"; exit 1;
}
echo "$bench_json" | jq -e '.storage_benchmark.random_4k_iops' >/dev/null || {
    echo "❌ Missing IOPS in bench JSON"; exit 1;
}
echo "$bench_json" | jq -e '.network_benchmark.cdn_download_mb_s' >/dev/null || {
    echo "❌ Missing download speed in bench JSON"; exit 1;
}
echo "modules/diagnostics/bench.sh passed ✅"

echo ">>> [5/6] Testing setup.sh --bench integration..."
setup_bench="$("$SCRIPT_DIR/setup.sh" --bench --dry-run)"
echo "$setup_bench" | grep -q "SYSTEM & NETWORK BENCHMARK" || {
    echo "❌ setup.sh --bench failed to run benchmark"; exit 1;
}
echo "setup.sh --bench passed ✅"

echo ">>> [6/6] Testing standalone bundle --bench execution..."
bundle_bench="$("$SCRIPT_DIR/dist/server-setup-standalone.sh" --bench --dry-run)"
echo "$bundle_bench" | grep -q "SYSTEM SPECIFICATIONS" || {
    echo "❌ dist/server-setup-standalone.sh --bench failed"; exit 1;
}
echo "dist/server-setup-standalone.sh --bench passed ✅"

echo "✅ All Pre-Flight & Diagnostics tests passed successfully!"
