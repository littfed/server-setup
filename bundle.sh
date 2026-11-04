#!/usr/bin/env bash
# ==============================================================================
# bundle.sh - Packages server-setup into a single standalone installer
# Output: dist/server-setup-standalone.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
OUTPUT_FILE="$DIST_DIR/server-setup-standalone.sh"

mkdir -p "$DIST_DIR"

echo ">>> Packaging server-setup into $OUTPUT_FILE..."

# Create a temporary archive of core, adapters, modules, and setup.sh
TMP_TAR="$(mktemp)"
tar -czf "$TMP_TAR" -C "$SCRIPT_DIR" setup.sh core adapters modules

PAYLOAD_B64="$(base64 -w 0 "$TMP_TAR")"
rm -f "$TMP_TAR"

cat <<'EOF' > "$OUTPUT_FILE"
#!/usr/bin/env bash
# ==============================================================================
# Server-Setup Standalone Self-Extracting Installer
# https://github.com/littfed/server-setup
# ==============================================================================

set -euo pipefail

TMP_DIR="$(mktemp -d -t server-setup-XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Extract payload
base64 -d <<'PAYLOAD_MARKER' | tar -xzf - -C "$TMP_DIR"
EOF

echo "$PAYLOAD_B64" >> "$OUTPUT_FILE"

cat <<'EOF' >> "$OUTPUT_FILE"
PAYLOAD_MARKER

# Execute unified dispatcher inside temporary extracted directory
exec "$TMP_DIR/setup.sh" "$@"
EOF

chmod +x "$OUTPUT_FILE"
echo "✅ Successfully built $OUTPUT_FILE ($(du -h "$OUTPUT_FILE" | awk '{print $1}'))."
