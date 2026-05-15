#!/usr/bin/env bash
# IAI-MCP SessionStart hook — update availability check.
#
# Fires once per new session (matcher: startup). Compares the installed
# iai-mcp version against the latest GitHub release. Prints one line to
# stdout when an update is available; silent otherwise.
#
# Design goals:
#   - Zero tokens when up to date (no stdout → no additionalContext).
#   - Fast: cache result for 6 h; fetch runs in a detached background
#     subshell so this hook returns in < 50 ms.
#   - Fail-safe: any error exits 0 silently.
#
# The hook is registered by `iai-mcp capture-hooks install` alongside
# the capture and recall hooks.

set -u

cache="$HOME/.iai-mcp/.update-check-cache"
TTL=21600  # 6 hours in seconds

# --- locate installed version ----------------------------------------------
installed=""

cli_cache="$HOME/.iai-mcp/.cli-path"
if [[ -n "${IAI_MCP_SESSION_RECALL_CLI:-}" && -x "${IAI_MCP_SESSION_RECALL_CLI:-}" ]]; then
  installed=$("$IAI_MCP_SESSION_RECALL_CLI" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi

if [[ -z "$installed" && -f "$cli_cache" ]]; then
  cached_cli=$(cat "$cli_cache" 2>/dev/null || true)
  if [[ -n "$cached_cli" && -x "$cached_cli" ]]; then
    installed=$("$cached_cli" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  fi
fi

if [[ -z "$installed" ]]; then
  candidates=(
    "$HOME/IAI-MCP/.venv/bin/iai-mcp"
    "/usr/local/bin/iai-mcp"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      installed=$("$candidate" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      [[ -n "$installed" ]] && break
    fi
  done
fi

[[ -z "$installed" ]] && exit 0

# --- check cache -----------------------------------------------------------
now=$(date +%s)
if [[ -f "$cache" ]]; then
  cached_ts=$(head -1 "$cache" 2>/dev/null)
  if [[ -n "$cached_ts" ]] && (( now - cached_ts < TTL )); then
    latest=$(sed -n '2p' "$cache" 2>/dev/null)
    if [[ -n "$latest" && "$installed" != "$latest" ]]; then
      newer=$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | tail -1)
      if [[ "$newer" == "$latest" ]]; then
        echo "iai-mcp update available: v${installed} → v${latest}. See https://github.com/CodeAbra/iai-mcp/releases/tag/v${latest}"
      fi
    fi
    exit 0
  fi
fi

# --- background fetch (non-blocking) --------------------------------------
# Spawns a detached subshell that writes the cache file. This hook returns
# immediately so session startup is never blocked by network latency.
# On the NEXT session start, the fresh cache is read and the banner shown.
(
  latest=""
  if command -v gh >/dev/null 2>&1; then
    latest=$(gh api repos/CodeAbra/iai-mcp/releases/latest --jq '.tag_name' 2>/dev/null | sed 's/^v//')
  elif command -v curl >/dev/null 2>&1; then
    latest=$(curl -sf --max-time 5 \
      "https://api.github.com/repos/CodeAbra/iai-mcp/releases/latest" 2>/dev/null \
      | grep '"tag_name"' | sed 's/.*"v\?\([^"]*\)".*/\1/')
  fi
  if [[ -n "$latest" ]]; then
    mkdir -p "$(dirname "$cache")" 2>/dev/null
    printf '%s\n%s\n' "$(date +%s)" "$latest" > "$cache" 2>/dev/null
  fi
) &
disown 2>/dev/null

exit 0
