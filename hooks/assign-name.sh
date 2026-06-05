#!/usr/bin/env bash
# Picks a random name from ~/.claude/names.txt and injects it as a system reminder.

NAMES_FILE="$HOME/.claude/names.txt"

if [[ ! -f "$NAMES_FILE" ]]; then
  exit 0
fi

# Read session_id from hook input
hook_input=$(cat)
session_id=$(echo "$hook_input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)

# Count lines and pick a random one (macOS-compatible: no shuf)
total=$(wc -l < "$NAMES_FILE" | tr -d ' ')
if [[ "$total" -eq 0 ]]; then
  exit 0
fi

# Use $RANDOM (0-32767) to pick a line; add 1 since sed lines are 1-indexed
line_num=$(( (RANDOM % total) + 1 ))
name=$(sed -n "${line_num}p" "$NAMES_FILE")

# Persist names durably in ~/.claude/session-names.json so they survive reboots
NAMES_DB="$HOME/.claude/session-names.json"

if [[ -n "$session_id" ]]; then
  ctx_file="/tmp/claude-custom-context-${session_id}.json"

  # Priority: durable store > existing context file > new random name
  if [[ -f "$ctx_file" ]]; then
    existing=$(cat "$ctx_file")
  else
    existing="{}"
  fi
  printf '%s' "$existing" | python3 -c "
import json, sys, random
d = json.load(sys.stdin)
new_name = '$name'
new_emoji = chr(random.Random('$session_id').randint(0x1F300, 0x1F9FF))

# Load durable store
db = {}
try: db = json.load(open('$NAMES_DB'))
except: pass
entry = db.get('$session_id', {})

# Priority: durable store > existing ctx file > new random
d['name']  = entry.get('name')  or d.get('name')  or new_name
d['emoji'] = entry.get('emoji') or d.get('emoji') or new_emoji

# Write back to durable store
db['$session_id'] = {'name': d['name'], 'emoji': d['emoji']}
json.dump(db, open('$NAMES_DB', 'w'), indent=2)
print(json.dumps(d))
" > "$ctx_file"

  name=$(python3 -c "import json; print(json.load(open('$ctx_file'))['name'])" 2>/dev/null || echo "$name")
fi

# Print plain text — Claude Code injects stdout from SessionStart hooks as a system-reminder
printf 'Your name for this session is: %s\n' "$name"
