#!/usr/bin/env bash
# Temporary probe to test what version SessionStart hooks see
OUTPUT="/tmp/cofounder-version-probe.txt"
echo "=== Version Probe $(date) ===" > "$OUTPUT"
echo "CLAUDE_PLUGIN_ROOT: $CLAUDE_PLUGIN_ROOT" >> "$OUTPUT"
PLUGIN_JSON="$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json"
if [ -f "$PLUGIN_JSON" ]; then
  echo "plugin.json contents:" >> "$OUTPUT"
  cat "$PLUGIN_JSON" >> "$OUTPUT"
else
  echo "plugin.json NOT FOUND at $PLUGIN_JSON" >> "$OUTPUT"
fi
