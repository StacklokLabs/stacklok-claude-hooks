#!/bin/bash
# ToolHive MCP Governance Hook - Common Functions
# Shared code for stacklok-hook variants
#
# This file is sourced by the plugin wrapper scripts.
# Expects REGISTRY_ONLY to be set before sourcing (true or false).
#
# Input: JSON via stdin with tool_name in format mcp__<server>__<tool>
# Output: JSON with hookSpecificOutput containing permissionDecision

# ----------------------------
# Configuration
# ----------------------------
LOG_DIR="$HOME/temp_logs"
LOG_FILE="$LOG_DIR/toolhive-hook-bash.log"

# Global variable to store ToolHive JSON response
TOOLHIVE_JSON=""
# ----------------------------
# Logging (disabled by default, enable with THV_HOOK_DEBUG=true)
# ----------------------------
log() {
    if [[ "${THV_HOOK_DEBUG:-}" == "true" ]]; then
        mkdir -p "$LOG_DIR"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    fi
}

# ----------------------------
# Parse MCP tool name
# ----------------------------
# Format: mcp__<server>__<tool>
# Returns: server name (part between first and second __)
parse_mcp_server() {
    local tool_name="$1"

    # Check if it starts with mcp__
    if [[ ! "$tool_name" =~ ^mcp__ ]]; then
        echo ""
        return 0
    fi

    # Split on __ and get the second part (index 1)
    # mcp__server__tool -> parts: ["mcp", "server", "tool"]
    local without_prefix="${tool_name#mcp__}"  # Remove mcp__ prefix
    local server_name="${without_prefix%%__*}"  # Get everything before next __

    echo "$server_name"
}

# ----------------------------
# Fetch ToolHive data
# ----------------------------
# Sets TOOLHIVE_JSON global variable with the full thv list output
# Returns: 0 on success, 1 on failure
fetch_toolhive_data() {
    local raw_output=""

    # Query ToolHive with timeout
    if ! raw_output=$(timeout 5 thv list --format json 2>&1); then
        log "thv list command failed or timed out"
        TOOLHIVE_JSON=""
        return 1
    fi

    log "thv list output: $raw_output"

    # Handle thv warning messages - extract only the JSON part
    # Warnings appear before JSON, so extract from first [ character
    TOOLHIVE_JSON=$(echo "$raw_output" | sed -n '/^\[/,$p')

    if [[ -z "$TOOLHIVE_JSON" ]]; then
        log "No valid JSON in thv output"
        return 1
    fi

    return 0
}

# ----------------------------
# Get ToolHive server names
# ----------------------------
# Requires: TOOLHIVE_JSON to be set (call fetch_toolhive_data first)
# Returns: newline-separated list of server names
get_toolhive_servers() {
    if [[ -z "$TOOLHIVE_JSON" ]]; then
        echo ""
        return 0
    fi

    # Extract server names from JSON array
    # Format: [{"name": "server1", ...}, {"name": "server2", ...}]
    local names
    names=$(echo "$TOOLHIVE_JSON" | jq -r '.[].name // empty' 2>/dev/null || echo "")

    echo "$names"
}

# ----------------------------
# Get ToolHive registry entries
# ----------------------------
# Returns: newline-separated list of registry images
get_registry_images() {
    local raw_output=""

    # Query ToolHive registry with timeout
    if ! raw_output=$(timeout 5 thv registry list --format json 2>&1); then
        log "thv registry list command failed or timed out"
        echo ""
        return 0
    fi

    # Handle thv warning messages - extract only the JSON part
    local registry_json
    registry_json=$(echo "$raw_output" | sed -n '/^\[/,$p')

    if [[ -z "$registry_json" ]]; then
        log "No valid JSON in thv registry output"
        echo ""
        return 0
    fi

    # Extract image names from registry
    local images
    images=$(echo "$registry_json" | jq -r '.[].image // empty' 2>/dev/null || echo "")

    echo "$images"
}

# ----------------------------
# Get ToolHive registry URLs
# ----------------------------
# Returns: newline-separated list of registry URLs
get_registry_urls() {
    local raw_output=""

    # Query ToolHive registry with timeout
    if ! raw_output=$(timeout 5 thv registry list --format json 2>&1); then
        log "thv registry list command failed or timed out"
        echo ""
        return 0
    fi

    log "thv registry output: $raw_output"

    # Handle thv warning messages - extract only the JSON part
    local registry_json
    registry_json=$(echo "$raw_output" | sed -n '/^\[/,$p')

    log "Parsed registry JSON: $registry_json"

    if [[ -z "$registry_json" ]]; then
        log "No valid JSON in thv registry output"
        echo ""
        return 0
    fi

    # Extract URLs from registry
    local urls
    urls=$(echo "$registry_json" | jq -r '.[].url // empty' 2>/dev/null || echo "")

    log "Extracted registry URLs: $urls"

    echo "$urls"
}

# ----------------------------
# Get server info from stored ToolHive JSON
# ----------------------------
# Args: server_name
# Returns: JSON object for the server or empty string
get_server_info() {
    local server_name="$1"

    if [[ -z "$TOOLHIVE_JSON" ]]; then
        echo ""
        return 0
    fi

    echo "$TOOLHIVE_JSON" | jq -r --arg name "$server_name" '.[] | select(.name == $name)' 2>/dev/null || echo ""
}

# ----------------------------
# Get remote URL for a server via thv export
# ----------------------------
# Args: server_name
# Returns: remote URL or empty string
get_server_remote_url() {
    local server_name="$1"
    local raw_output=""

    # Query thv export with timeout - use /dev/stdout as path to output to stdout
    if ! raw_output=$(timeout 5 thv export "$server_name" /dev/stdout --format json 2>&1); then
        log "thv export command failed for $server_name"
        echo ""
        return 0
    fi

    log "thv export output for $server_name: $raw_output"

    # Handle thv warning messages - extract only the JSON part
    local export_json
    export_json=$(echo "$raw_output" | sed -n '/^{/,$p')

    if [[ -z "$export_json" ]]; then
        log "No valid JSON in thv export output"
        echo ""
        return 0
    fi

    # Extract remote URL - look for remote_url field in the export
    local remote_url
    remote_url=$(echo "$export_json" | jq -r '.remote_url // empty' 2>/dev/null || echo "")

    echo "$remote_url"
}

# ----------------------------
# Check if server is in registry
# ----------------------------
# Args: server_name
# Returns: 0 if in registry, 1 if not
check_registry_match() {
    local server_name="$1"

    # Get server info from stored ToolHive JSON
    local server_info
    server_info=$(get_server_info "$server_name")

    if [[ -z "$server_info" ]]; then
        log "Server $server_name not found in ToolHive JSON"
        return 1
    fi

    # Check if server has remote flag (remote workload)
    local is_remote
    is_remote=$(echo "$server_info" | jq -r '.remote // false' 2>/dev/null || echo "false")

    log "Server $server_name is_remote=$is_remote"

    if [[ "$is_remote" == "true" ]]; then
        # Remote workload: compare remote_url against registry URLs
        local remote_url
        remote_url=$(get_server_remote_url "$server_name")

        if [[ -z "$remote_url" ]]; then
            log "Could not get remote URL for $server_name"
            return 1
        fi

        log "Remote URL for $server_name: $remote_url"

        local registry_urls
        registry_urls=$(get_registry_urls)

        while IFS= read -r reg_url; do
            [[ -z "$reg_url" ]] && continue
            if [[ "$remote_url" == "$reg_url" ]]; then
                log "Remote URL matches registry: $remote_url"
                return 0
            fi
        done <<< "$registry_urls"

        log "Remote URL not in registry"
        return 1
    else
        # Container workload: compare package against registry images
        local package
        package=$(echo "$server_info" | jq -r '.package // empty' 2>/dev/null || echo "")

        if [[ -z "$package" ]]; then
            log "No package found for $server_name"
            return 1
        fi

        log "Package for $server_name: $package"

        local registry_images
        registry_images=$(get_registry_images)

        while IFS= read -r reg_image; do
            [[ -z "$reg_image" ]] && continue
            if [[ "$package" == "$reg_image" ]]; then
                log "Package matches registry: $package"
                return 0
            fi
        done <<< "$registry_images"

        log "Package not in registry"
        return 1
    fi
}

# ----------------------------
# Output helpers
# ----------------------------
output_allow() {
    local server="$1"
    local reason="MCP server '$server' is managed by ToolHive"

    jq -n \
        --arg reason "$reason" \
        '{
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": $reason
            }
        }'
}

output_deny() {
    local tool_name="$1"
    local server="$2"

    local reason="MCP call to '$tool_name' blocked: server '$server' is not managed by Stacklok's ToolHive."
    local system_msg="MCP call to '$tool_name' blocked: server '$server' is not managed by Stacklok's ToolHive."

    jq -n \
        --arg reason "$reason" \
        --arg sysmsg "$system_msg" \
        '{
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": $reason
            },
            "systemMessage": $sysmsg
        }'
}

output_deny_registry() {
    local tool_name="$1"
    local server="$2"

    local reason="MCP call to '$tool_name' blocked: server '$server' is not from the configured ToolHive registry. Contact your administrator to add '$server' to the registry."
    local system_msg="MCP call to '$tool_name' blocked: server '$server' is not from the configured ToolHive registry. Contact your administrator to add '$server' to the registry."

    jq -n \
        --arg reason "$reason" \
        --arg sysmsg "$system_msg" \
        '{
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": $reason
            },
            "systemMessage": $sysmsg
        }'
}

output_deny_unavailable() {
    local tool_name="$1"
    local server="$2"

    local reason="MCP call to '$tool_name' blocked: ToolHive is unavailable. Cannot verify if server '$server' is managed."
    local system_msg="MCP call to '$tool_name' blocked: ToolHive is unavailable. Cannot verify if server '$server' is managed."

    jq -n \
        --arg reason "$reason" \
        --arg sysmsg "$system_msg" \
        '{
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": $reason
            },
            "systemMessage": $sysmsg
        }'
}

# ----------------------------
# Main
# ----------------------------
main() {
    log "=== Hook triggered ==="

    # Read JSON from stdin
    local input
    if ! input=$(cat); then
        log "Failed to read stdin"
        exit 0  # Allow on read error
    fi

    log "Input: $input"

    # Extract tool_name from input
    local tool_name
    tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null || echo "")

    if [[ -z "$tool_name" ]]; then
        log "No tool_name in input, allowing"
        exit 0
    fi

    log "Tool name: $tool_name"

    # Parse server name from MCP tool
    local server_name
    server_name=$(parse_mcp_server "$tool_name")

    if [[ -z "$server_name" ]]; then
        # Check if it's an MCP tool with empty server name
        if [[ "$tool_name" =~ ^mcp__ ]]; then
            # MCP tool with empty server name - deny
            log "MCP tool with empty server name, denying"
            output_deny "$tool_name" "(empty)"
            log "=== Hook complete ==="
            exit 0
        fi
        # Not an MCP tool format, allow (shouldn't happen with matcher)
        log "Not an MCP tool format, allowing"
        exit 0
    fi

    log "MCP server: $server_name"

    # Fetch ToolHive data (sets TOOLHIVE_JSON global)
    if ! fetch_toolhive_data; then
        # ToolHive unavailable - fail closed (deny)
        log "ToolHive unavailable, denying (fail-closed)"
        output_deny_unavailable "$tool_name" "$server_name"
        log "=== Hook complete ==="
        exit 0
    fi

    # Get server names from the fetched data
    local toolhive_servers
    toolhive_servers=$(get_toolhive_servers)

    # Empty server list is valid (no servers running) - not an error
    # The server simply won't be found in an empty list
    log "ToolHive servers: ${toolhive_servers:-<none>}"

    # Check if server is in ToolHive list
    local found=false
    while IFS= read -r th_server; do
        [[ -z "$th_server" ]] && continue
        if [[ "$server_name" == "$th_server" ]]; then
            found=true
            break
        fi
    done <<< "$toolhive_servers"

    if [[ "$found" == "true" ]]; then
        # Server is in ToolHive, check registry-only mode
        if [[ "${REGISTRY_ONLY:-false}" == "true" ]]; then
            log "Registry-only mode enabled, checking registry"
            if check_registry_match "$server_name"; then
                log "Decision: ALLOW (in registry)"
                output_allow "$server_name"
            else
                log "Decision: DENY (not in registry)"
                output_deny_registry "$tool_name" "$server_name"
            fi
        else
            log "Decision: ALLOW"
            output_allow "$server_name"
        fi
        log "=== Hook complete ==="
        exit 0
    else
        log "Decision: DENY"
        output_deny "$tool_name" "$server_name"
        log "=== Hook complete ==="
        exit 0
    fi
}

