#!/usr/bin/env bash
# Installs claude-statusline-config into ~/.claude/
# Usage: bash install.sh

set -euo pipefail

DEST="$HOME/.claude"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing to $DEST ..."

mkdir -p "$DEST/hooks"

cp "$REPO_DIR/statusline-command.sh"  "$DEST/statusline-command.sh"
cp "$REPO_DIR/statusline-context.py"  "$DEST/statusline-context.py"
cp "$REPO_DIR/hooks/assign-name.sh"   "$DEST/hooks/assign-name.sh"
cp "$REPO_DIR/hooks/extract-prs.py"   "$DEST/hooks/extract-prs.py"
chmod +x "$DEST/statusline-command.sh" "$DEST/hooks/assign-name.sh"

# Copy names list only if not already present (don't overwrite customized list)
if [[ ! -f "$DEST/names.txt" ]]; then
  cp "$REPO_DIR/names.txt" "$DEST/names.txt"
  echo "Installed names.txt ($(wc -l < "$DEST/names.txt" | tr -d ' ') names)"
else
  echo "Skipped names.txt (already exists)"
fi

# Copy example config only if none exists yet
if [[ ! -f "$DEST/statusline-config.json" ]]; then
  cp "$REPO_DIR/statusline-config.example.json" "$DEST/statusline-config.json"
  echo "Created statusline-config.json from example — edit it to configure ticket URLs etc."
else
  echo "Skipped statusline-config.json (already exists)"
fi

# Patch ~/.claude/settings.json
SETTINGS="$DEST/settings.json"
if [[ ! -f "$SETTINGS" ]]; then
  echo '{}' > "$SETTINGS"
fi

python3 - "$SETTINGS" <<'EOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

# statusLine
cfg["statusLine"] = "bash ~/.claude/statusline-command.sh"

# hooks
hooks = cfg.setdefault("hooks", {})

# SessionStart
ss = hooks.setdefault("SessionStart", [])
ss_cmd = "bash ~/.claude/hooks/assign-name.sh"
if not any(
    any(h.get("command") == ss_cmd for h in entry.get("hooks", []))
    for entry in ss
):
    ss.append({"hooks": [{"type": "command", "command": ss_cmd, "timeout": 5}]})

# PostToolUse
ptu = hooks.setdefault("PostToolUse", [])
ptu_cmd = "python3 ~/.claude/hooks/extract-prs.py"
if not any(
    any(h.get("command") == ptu_cmd for h in entry.get("hooks", []))
    for entry in ptu
):
    ptu.append({"hooks": [{"type": "command", "command": ptu_cmd, "timeout": 5, "async": True}]})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("Updated settings.json")
EOF

echo ""
echo "Done. Restart Claude Code to activate."
echo ""
echo "To configure ticket links, edit: $DEST/statusline-config.json"
