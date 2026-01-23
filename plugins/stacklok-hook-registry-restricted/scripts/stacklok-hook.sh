#!/bin/bash
# ToolHive MCP Governance Hook for Claude Code (Registry-Restricted)
# Only allows MCP calls to servers that are in the ToolHive registry
#
# For default mode (any ToolHive-managed server), use the stacklok-hook plugin instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Registry-restricted mode: only allow servers from the ToolHive registry
REGISTRY_ONLY=true

source "${SCRIPT_DIR}/common/stacklok-common.sh"
main
