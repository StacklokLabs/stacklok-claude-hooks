#!/bin/bash
# Unit tests for stacklok-hook.sh (registry-restricted mode)
#
# Run from repo root: ./plugins/stacklok-hook-registry-restricted/tests/stacklok-hook-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../scripts/stacklok-hook.sh"

if [[ ! -x "$HOOK_SCRIPT" ]]; then
    echo "ERROR: $HOOK_SCRIPT not found or not executable"
    exit 1
fi

# ----------------------------
# Create mock directory and setup
# ----------------------------
TMPDIR="$(mktemp -d)"
export PATH="$TMPDIR:$PATH"

# Mock timeout command to just run the command directly (for portability)
cat > "$TMPDIR/timeout" <<'EOF'
#!/bin/bash
shift  # Remove timeout value
exec "$@"
EOF
chmod +x "$TMPDIR/timeout"

# ----------------------------
# Create mock thv command
# ----------------------------
# Servers:
#   - mkp: container workload, package in registry
#   - fetch: container workload, package in registry
#   - github: remote workload, remote_url in registry
#   - localserver: container workload, NOT in registry
#   - customremote: remote workload, NOT in registry
create_mock_thv() {
    cat > "$TMPDIR/thv" <<'THVEOF'
#!/bin/bash
if [[ "$1" == "list" && "$2" == "--format" && "$3" == "json" ]]; then
    cat <<JSON
[
  {"name": "mkp", "status": "running", "package": "ghcr.io/stacklok/mkp:latest", "remote": false},
  {"name": "fetch", "status": "running", "package": "ghcr.io/stacklok/fetch:latest", "remote": false},
  {"name": "github", "status": "running", "package": "", "remote": true},
  {"name": "localserver", "status": "running", "package": "local/myserver:dev", "remote": false},
  {"name": "customremote", "status": "running", "package": "", "remote": true}
]
JSON
elif [[ "$1" == "registry" && "$2" == "list" && "$3" == "--format" && "$4" == "json" ]]; then
    cat <<JSON
[
  {"name": "mkp", "image": "ghcr.io/stacklok/mkp:latest", "url": ""},
  {"name": "fetch", "image": "ghcr.io/stacklok/fetch:latest", "url": ""},
  {"name": "github-official", "image": "", "url": "https://api.github.com/mcp"}
]
JSON
elif [[ "$1" == "export" && "$4" == "--format" && "$5" == "json" ]]; then
    server_name="$2"
    if [[ "$server_name" == "github" ]]; then
        cat <<JSON
{"name": "github", "remote_url": "https://api.github.com/mcp"}
JSON
    elif [[ "$server_name" == "customremote" ]]; then
        cat <<JSON
{"name": "customremote", "remote_url": "https://custom.example.com/mcp"}
JSON
    else
        echo "{}"
    fi
else
    exit 1
fi
THVEOF
    chmod +x "$TMPDIR/thv"
}

# Create mock thv that fails (for fail-closed tests)
create_failing_thv() {
    cat > "$TMPDIR/thv" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TMPDIR/thv"
}

# ----------------------------
# Test harness
# ----------------------------
pass=0
fail=0

run_test() {
    local name="$1"
    local input_json="$2"
    local expected_decision="$3"

    echo "=== Test: $name ==="

    local output
    output="$(echo "$input_json" | bash "$HOOK_SCRIPT" 2>/dev/null || true)"

    local decision
    decision="$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || echo "")"

    if [[ "$decision" == "$expected_decision" ]]; then
        echo "PASS (decision=$decision)"
        ((pass++))
    else
        echo "FAIL (got '$decision', expected '$expected_decision')"
        echo "Output: $output"
        ((fail++))
    fi
    echo
}

run_message_test() {
    local name="$1"
    local input_json="$2"
    local expected_pattern="$3"

    echo "=== Test: $name ==="

    local output
    output="$(echo "$input_json" | bash "$HOOK_SCRIPT" 2>/dev/null || true)"

    local reason
    reason="$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || echo "")"

    if [[ "$reason" == *"$expected_pattern"* ]]; then
        echo "PASS (message contains '$expected_pattern')"
        ((pass++))
    else
        echo "FAIL (message does not contain '$expected_pattern')"
        echo "Reason: $reason"
        ((fail++))
    fi
    echo
}

echo "============================================="
echo "ToolHive Hook Test Suite (Registry-Restricted Mode)"
echo "============================================="
echo
echo "This plugin only allows servers from the ToolHive registry."
echo "For default mode (any ToolHive server), use stacklok-hook."
echo

# ----------------------------
# Setup for most tests
# ----------------------------
create_mock_thv

# ----------------------------
# A. Basic Server Matching Tests
# ----------------------------
echo "============================================="
echo "A. Basic Server Matching Tests"
echo "============================================="
echo

run_test \
    "unknown denied (not in ToolHive)" \
    '{"tool_name": "mcp__unknown__tool", "tool_input": {}}' \
    "deny"

run_test \
    "MKP denied (case-sensitive)" \
    '{"tool_name": "mcp__MKP__tool", "tool_input": {}}' \
    "deny"

run_test \
    "mkp2 denied (exact match required)" \
    '{"tool_name": "mcp__mkp2__tool", "tool_input": {}}' \
    "deny"

# ----------------------------
# B. Edge Cases Tests
# ----------------------------
echo "============================================="
echo "B. Edge Cases Tests"
echo "============================================="
echo

run_test \
    "empty tool_name - allow (hook not applicable)" \
    '{"tool_input": {}}' \
    ""

run_test \
    "non-MCP tool (Bash) - allow" \
    '{"tool_name": "Bash", "tool_input": {"command": "ls"}}' \
    ""

run_test \
    "non-MCP tool (Write) - allow" \
    '{"tool_name": "Write", "tool_input": {"file_path": "/tmp/test"}}' \
    ""

run_test \
    "malformed mcp (single underscore) - allow" \
    '{"tool_name": "mcp_server_tool", "tool_input": {}}' \
    ""

run_test \
    "malformed json - allow" \
    'not valid json' \
    ""

run_test \
    "empty server (mcp____tool) - deny" \
    '{"tool_name": "mcp____tool", "tool_input": {}}' \
    "deny"

# ----------------------------
# C. Registry-Restricted Mode - Container Workloads
# ----------------------------
echo "============================================="
echo "C. Registry-Restricted Mode - Container Workloads"
echo "============================================="
echo

run_test \
    "mkp allowed (package in registry)" \
    '{"tool_name": "mcp__mkp__tool", "tool_input": {}}' \
    "allow"

run_test \
    "fetch allowed (package in registry)" \
    '{"tool_name": "mcp__fetch__tool", "tool_input": {}}' \
    "allow"

run_test \
    "localserver denied (not in registry)" \
    '{"tool_name": "mcp__localserver__tool", "tool_input": {}}' \
    "deny"

# ----------------------------
# D. Registry-Restricted Mode - Remote Workloads
# ----------------------------
echo "============================================="
echo "D. Registry-Restricted Mode - Remote Workloads"
echo "============================================="
echo

run_test \
    "github allowed (remote_url in registry)" \
    '{"tool_name": "mcp__github__tool", "tool_input": {}}' \
    "allow"

run_test \
    "customremote denied (remote_url not in registry)" \
    '{"tool_name": "mcp__customremote__tool", "tool_input": {}}' \
    "deny"

# ----------------------------
# E. Error Message Verification
# ----------------------------
echo "============================================="
echo "E. Error Message Verification"
echo "============================================="
echo

run_message_test \
    "Deny message contains 'is not managed by' when not in ToolHive" \
    '{"tool_name": "mcp__unknown__tool", "tool_input": {}}' \
    "is not managed by"

run_message_test \
    "Deny message contains server name for ToolHive rejection" \
    '{"tool_name": "mcp__unknown__tool", "tool_input": {}}' \
    "unknown"

run_message_test \
    "Registry deny contains 'not from the configured ToolHive registry'" \
    '{"tool_name": "mcp__localserver__tool", "tool_input": {}}' \
    "not from the configured ToolHive registry"

run_message_test \
    "Registry deny contains 'Contact your administrator'" \
    '{"tool_name": "mcp__localserver__tool", "tool_input": {}}' \
    "Contact your administrator"

# ----------------------------
# F. ToolHive Unavailable (Fail-Closed)
# ----------------------------
echo "============================================="
echo "F. ToolHive Unavailable (Fail-Closed)"
echo "============================================="
echo

create_failing_thv

run_test \
    "thv fails - deny (fail-closed)" \
    '{"tool_name": "mcp__mkp__tool", "tool_input": {}}' \
    "deny"

run_message_test \
    "thv unavailable message" \
    '{"tool_name": "mcp__mkp__tool", "tool_input": {}}' \
    "ToolHive is unavailable"

# ----------------------------
# Summary
# ----------------------------
echo "============================================="
echo "Summary: $pass passed, $fail failed"
echo "============================================="

# Cleanup
rm -rf "$TMPDIR"

[[ "$fail" -ne 0 ]] && exit 1
exit 0
