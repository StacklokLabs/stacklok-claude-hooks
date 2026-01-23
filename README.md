# Claude Code Hooks: ToolHive MCP Governance

A [Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code) that restricts MCP (Model Context Protocol) tool calls to only servers managed by [ToolHive](https://github.com/stacklok/toolhive).

## Why ToolHive

MCP adoption spreads organically: MCP configurations get shared, copied from READMEs, and rarely cleaned up. Security teams lose visibility into what's connected and what data is flowing where causing security risks and compliance headaches.

[ToolHive](https://github.com/stacklok/toolhive) is an open-source platform that brings enterprise-grade security to MCP deployment. It provides a curated registry of approved servers, isolated container runtimes, centralized policy enforcement, and audit logging—without blocking developers from using the tools they need.

This hook is the Claude Code integration. It intercepts every MCP call before execution and verifies the target server is ToolHive-managed. Unauthorized servers are blocked with a clear error message.

## What it does

When Claude Code attempts to use an MCP tool, this hook:

1. Intercepts the call before execution (PreToolUse hook)
2. Parses the tool name (`mcp__<server>__<tool>`) to extract the server name
3. Queries ToolHive (`thv list --format json`) to get managed servers
4. **Fail-closed**: If ToolHive is unavailable, denies the call
5. Allows or denies based on plugin mode (see Available Plugins below)
6. Returns structured JSON to Claude Code indicating allow/deny and reason

## Available Plugins

This marketplace provides two plugin variants:

| Plugin | Description |
|--------|-------------|
| `stacklok-hook` | Allows any MCP server managed by ToolHive |
| `stacklok-hook-registry-restricted` | Only allows servers from the ToolHive registry |

### Which plugin should I use?

- **stacklok-hook** (Default): Use this if you trust all servers your team adds to ToolHive. Any server in `thv list` is allowed.

- **stacklok-hook-registry-restricted**: Use this for stricter enterprise environments. Servers must be in ToolHive AND match the ToolHive registry:
  - Container workloads: The server's package must match an image in the registry
  - Remote workloads: The server's remote URL must match a URL in the registry

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed
- [jq](https://jqlang.github.io/jq/) - JSON processor (`brew install jq` on macOS)
- [ToolHive](https://github.com/stacklok/toolhive) (`thv` CLI)

## Installation

### Option 1: Plugin Marketplace (Recommended)

1. Launch Claude Code in any directory:
   ```bash
   claude
   ```

2. Add the marketplace:
   ```
   /plugin marketplace add https://github.com/StacklokLabs/claude-hooks
   ```

3. Install your preferred plugin:
   ```
   /plugin install stacklok-hook
   ```
   Or for registry-restricted mode:
   ```
   /plugin install stacklok-hook-registry-restricted
   ```

4. Select "Install for you (user scope)" when prompted.

5. Exit and restart Claude Code.

### Option 2: Manual Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/StacklokLabs/claude-hooks.git
   cd claude-hooks
   ```

2. Copy the plugin to your Claude Code plugins directory:
   ```bash
   mkdir -p ~/.claude/plugins
   # For default mode:
   cp -r plugins/stacklok-hook ~/.claude/plugins/
   chmod +x ~/.claude/plugins/stacklok-hook/scripts/stacklok-hook.sh

   # OR for registry-restricted mode:
   cp -r plugins/stacklok-hook-registry-restricted ~/.claude/plugins/
   chmod +x ~/.claude/plugins/stacklok-hook-registry-restricted/scripts/stacklok-hook.sh
   ```

3. Restart Claude Code.

## Uninstallation

```
/plugin uninstall stacklok-hook
```
Or for registry-restricted:
```
/plugin uninstall stacklok-hook-registry-restricted
```

Or manually remove:
```bash
rm -rf ~/.claude/plugins/stacklok-hook
# or
rm -rf ~/.claude/plugins/stacklok-hook-registry-restricted
```

## Testing

Run the unit tests (mocks the `thv` CLI):

```bash
# Test default mode plugin
./plugins/stacklok-hook/tests/stacklok-hook-test.sh

# Test registry-restricted mode plugin
./plugins/stacklok-hook-registry-restricted/tests/stacklok-hook-test.sh
```

## How it works

The hook (`scripts/stacklok-hook.sh`):

1. Receives MCP call details as JSON via stdin
2. Extracts `tool_name` (format: `mcp__<server>__<tool>`)
3. Parses out the server name
4. Queries `thv list --format json` to get managed servers
5. For registry-restricted mode: Also checks `thv registry list --format json`
6. Returns structured JSON:
   - Allow: `{"hookSpecificOutput": {"permissionDecision": "allow", ...}}`
   - Deny: `{"hookSpecificOutput": {"permissionDecision": "deny", ...}, "systemMessage": "..."}`

### Example Input

```json
{
  "session_id": "abc123",
  "hook_event_name": "PreToolUse",
  "tool_name": "mcp__chrome-devtools-mcp__take_screenshot",
  "tool_input": {}
}
```

### Example Output (Allow)

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "MCP server 'chrome-devtools-mcp' is managed by ToolHive"
  }
}
```

### Example Output (Deny - Not in ToolHive)

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "MCP call to 'mcp__evil-server__tool' blocked: server 'evil-server' is not managed by Stacklok's ToolHive."
  },
  "systemMessage": "MCP call to 'mcp__evil-server__tool' blocked: server 'evil-server' is not managed by Stacklok's ToolHive."
}
```

### Example Output (Deny - Not in Registry)

When using `stacklok-hook-registry-restricted` and the server is in ToolHive but not in the registry:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "MCP call to 'mcp__local-server__tool' blocked: server 'local-server' is not from the configured ToolHive registry. Contact your administrator to add 'local-server' to the registry."
  },
  "systemMessage": "MCP call to 'mcp__local-server__tool' blocked: server 'local-server' is not from the configured ToolHive registry. Contact your administrator to add 'local-server' to the registry."
}
```

## Configuration

### Debug Logging

Enable debug logs by setting the environment variable:

```bash
export THV_HOOK_DEBUG=true
```

Logs are written to `~/temp_logs/toolhive-hook-bash.log`.

## Troubleshooting

### Hook not triggering

1. Verify the plugin is installed: `/plugin list`
2. Check that the tool name matches the pattern `mcp__.*`
3. Restart Claude Code after installation

### jq command not found

Install jq:
```bash
brew install jq  # macOS
apt install jq   # Ubuntu/Debian
```

### thv command not found

Install ToolHive from: https://github.com/stacklok/toolhive

### Permission denied

Make sure the script is executable:
```bash
chmod +x ~/.claude/plugins/stacklok-hook/scripts/stacklok-hook.sh
```

## License

Apache 2.0
