#!/usr/bin/env bash
# Installs claude-statusline-config into ~/.claude/
# Usage: bash install.sh [--force]
#   --force  overwrite existing files without prompting

set -euo pipefail

DEST="$HOME/.claude"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

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
  local src="$1" dst="$2" label="$3"
  if [[ -f "$dst" ]] && ! diff -q "$src" "$dst" &>/dev/null; then
    echo "  $label already exists and differs."
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

# ── Try to build the Go binary (fast path) ───────────────────────────────────
USE_GO=0
if command -v go &>/dev/null; then
  echo "  Building Go binary..."
  if go build -o "$DEST/statusline" "$REPO_DIR" 2>/dev/null; then
    chmod +x "$DEST/statusline"
    echo "  Built ~/.claude/statusline"
    USE_GO=1
  else
    echo "  Go build failed, falling back to Python scripts."
  fi
else
  echo "  Go not found, using Python scripts."
fi

# ── Python fallback scripts (always installed, used when Go unavailable) ─────
install_file "$REPO_DIR/statusline-command.sh" "$DEST/statusline-command.sh" "statusline-command.sh"
install_file "$REPO_DIR/statusline-context.py"  "$DEST/statusline-context.py"  "statusline-context.py"
chmod +x "$DEST/statusline-command.sh"

# ── Hooks (always installed) ──────────────────────────────────────────────────
install_file "$REPO_DIR/hooks/assign-name.sh" "$DEST/hooks/assign-name.sh" "hooks/assign-name.sh"
install_file "$REPO_DIR/hooks/extract-prs.py" "$DEST/hooks/extract-prs.py" "hooks/extract-prs.py"
chmod +x "$DEST/hooks/assign-name.sh"

# names.txt: never overwrite
if [[ ! -f "$DEST/names.txt" ]]; then
  cp "$REPO_DIR/names.txt" "$DEST/names.txt"
  echo "  Installed names.txt ($(wc -l < "$DEST/names.txt" | tr -d ' ') names)"
else
  echo "  Skipped names.txt (already exists)"
fi

# statusline-config.json: never overwrite
if [[ ! -f "$DEST/statusline-config.json" ]]; then
  cp "$REPO_DIR/statusline-config.example.json" "$DEST/statusline-config.json"
  echo "  Created statusline-config.json — edit it to configure ticket URLs etc."
else
  echo "  Skipped statusline-config.json (already exists)"
fi

# ── Patch settings.json ───────────────────────────────────────────────────────
SETTINGS="$DEST/settings.json"
[[ ! -f "$SETTINGS" ]] && echo '{}' > "$SETTINGS"

if [[ "$USE_GO" -eq 1 ]]; then
  OUR_STATUSLINE="~/.claude/statusline"
else
  OUR_STATUSLINE="bash ~/.claude/statusline-command.sh"
fi

python3 - "$SETTINGS" "$FORCE" "$OUR_STATUSLINE" <<'EOF'
import json, sys

path, force, our_cmd = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
# Also accept the other variant as "ours" so upgrades don't prompt
our_variants = {"~/.claude/statusline", "bash ~/.claude/statusline-command.sh"}

with open(path) as f:
    cfg = json.load(f)

existing = cfg.get("statusLine", "")
if existing and existing not in our_variants:
    print(f"  settings.json already has statusLine: {existing!r}")
    if not force:
        answer = input("  Overwrite statusLine? [y/N] ")
        if not answer.strip().lower().startswith("y"):
            print("  Skipped statusLine.")
            our_cmd = None
    if our_cmd is not None:
        cfg["statusLine"] = our_cmd
        print(f"  Set statusLine -> {our_cmd}")
elif existing != our_cmd:
    cfg["statusLine"] = our_cmd
    print(f"  Set statusLine -> {our_cmd}")

hooks = cfg.setdefault("hooks", {})

ss = hooks.setdefault("SessionStart", [])
ss_cmd = "bash ~/.claude/hooks/assign-name.sh"
if not any(any(h.get("command") == ss_cmd for h in e.get("hooks", [])) for e in ss):
    ss.append({"hooks": [{"type": "command", "command": ss_cmd, "timeout": 5}]})
    print("  Added SessionStart hook")

ptu = hooks.setdefault("PostToolUse", [])
ptu_cmd = "python3 ~/.claude/hooks/extract-prs.py"
if not any(any(h.get("command") == ptu_cmd for h in e.get("hooks", [])) for e in ptu):
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
