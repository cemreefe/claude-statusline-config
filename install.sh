#!/usr/bin/env bash
# Installs claude-statusline-config into ~/.claude/
# Usage: bash install.sh [--force]
#   --force  overwrite existing files without prompting

set -euo pipefail

DEST="$HOME/.claude"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# Ask user to confirm overwriting a file or setting.
# Usage: confirm_overwrite "description of what will be overwritten"
# Returns 0 (yes) or exits 1 (no).
confirm_overwrite() {
  local desc="$1"
  printf "  Overwrite %s? [y/N] " "$desc"
  read -r answer </dev/tty
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "  Skipped."
    return 1
  fi
  return 0
}

install_file() {
  local src="$1"
  local dst="$2"
  local label="$3"

  if [[ -f "$dst" ]] && ! diff -q "$src" "$dst" &>/dev/null; then
    echo "  $label already exists and differs from the repo version."
    if [[ "$FORCE" -eq 1 ]] || confirm_overwrite "$label"; then
      cp "$src" "$dst"
      echo "  Installed $label"
    fi
  else
    cp "$src" "$dst"
    echo "  Installed $label"
  fi
}

echo "Installing to $DEST ..."
mkdir -p "$DEST/hooks"

install_file "$REPO_DIR/statusline-command.sh" "$DEST/statusline-command.sh" "statusline-command.sh"
install_file "$REPO_DIR/statusline-context.py"  "$DEST/statusline-context.py"  "statusline-context.py"
install_file "$REPO_DIR/hooks/assign-name.sh"   "$DEST/hooks/assign-name.sh"   "hooks/assign-name.sh"
install_file "$REPO_DIR/hooks/extract-prs.py"   "$DEST/hooks/extract-prs.py"   "hooks/extract-prs.py"
chmod +x "$DEST/statusline-command.sh" "$DEST/hooks/assign-name.sh"

# names.txt: never overwrite (user may have customised it)
if [[ ! -f "$DEST/names.txt" ]]; then
  cp "$REPO_DIR/names.txt" "$DEST/names.txt"
  echo "  Installed names.txt ($(wc -l < "$DEST/names.txt" | tr -d ' ') names)"
else
  echo "  Skipped names.txt (already exists — edit it to customise)"
fi

# statusline-config.json: never overwrite (user's own config)
if [[ ! -f "$DEST/statusline-config.json" ]]; then
  cp "$REPO_DIR/statusline-config.example.json" "$DEST/statusline-config.json"
  echo "  Created statusline-config.json — edit it to configure ticket URLs etc."
else
  echo "  Skipped statusline-config.json (already exists)"
fi

# Patch ~/.claude/settings.json
SETTINGS="$DEST/settings.json"
if [[ ! -f "$SETTINGS" ]]; then
  echo '{}' > "$SETTINGS"
fi

python3 - "$SETTINGS" "$FORCE" <<'EOF'
import json, sys

path = sys.argv[1]
force = sys.argv[2] == "1"

with open(path) as f:
    cfg = json.load(f)

OUR_CMD = "bash ~/.claude/statusline-command.sh"
existing_statusline = cfg.get("statusLine", "")

if existing_statusline and existing_statusline != OUR_CMD:
    print(f"  settings.json already has statusLine: {existing_statusline!r}")
    if not force:
        answer = input("  Overwrite statusLine? [y/N] ")
        if not answer.strip().lower().startswith("y"):
            print("  Skipped statusLine.")
            existing_statusline = None  # signal: don't update
        else:
            existing_statusline = ""  # signal: do update
    else:
        existing_statusline = ""

if existing_statusline == "" or not cfg.get("statusLine"):
    cfg["statusLine"] = OUR_CMD
    print("  Set statusLine in settings.json")

# hooks — idempotent additions
hooks = cfg.setdefault("hooks", {})

ss = hooks.setdefault("SessionStart", [])
ss_cmd = "bash ~/.claude/hooks/assign-name.sh"
if not any(
    any(h.get("command") == ss_cmd for h in entry.get("hooks", []))
    for entry in ss
):
    ss.append({"hooks": [{"type": "command", "command": ss_cmd, "timeout": 5}]})
    print("  Added SessionStart hook")

ptu = hooks.setdefault("PostToolUse", [])
ptu_cmd = "python3 ~/.claude/hooks/extract-prs.py"
if not any(
    any(h.get("command") == ptu_cmd for h in entry.get("hooks", []))
    for entry in ptu
):
    ptu.append({"hooks": [{"type": "command", "command": ptu_cmd, "timeout": 5, "async": True}]})
    print("  Added PostToolUse hook")

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
EOF

echo ""
echo "Done. Restart Claude Code to activate."
echo ""
echo "To configure ticket links, edit: $DEST/statusline-config.json"
