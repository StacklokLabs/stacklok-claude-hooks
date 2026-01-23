#!/bin/bash
# ToolHive MCP Governance Hook for Claude Code
# Allows MCP calls to any server managed by ToolHive
#
# For registry-restricted mode, use the stacklok-hook-registry-restricted plugin instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default mode: allow any ToolHive-managed server
REGISTRY_ONLY=false

source "${SCRIPT_DIR}/common/stacklok-common.sh"
main
