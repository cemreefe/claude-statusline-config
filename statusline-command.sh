#!/bin/sh
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
session_id=$(echo "$input" | jq -r '.session_id // ""')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five_hour=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')

# ANSI colors
C_RESET=$'\033[0m'
C_MODEL=$'\033[38;5;213m'   # pink/violet for model name
C_DIR=$'\033[38;5;75m'      # steel blue for directory
C_CTX=$'\033[38;5;149m'     # yellow-green for context %
C_COST=$'\033[38;5;215m'    # peach/orange for cost
C_RATE=$'\033[38;5;203m'    # salmon/red for rate limits
C_EMOJI=$'\033[0m'           # no extra color for emoji
C_SEP=$'\033[38;5;240m'     # dark grey separator

SEP="${C_SEP} · ${C_RESET}"

# Model shorthand: alpha words -> first letter, version tokens -> strip punctuation
# e.g. "Sonnet 4.6" -> "S46", "Claude Opus 4" -> "CO4"
model_short=$(printf '%s' "$model" | python3 -c "
import re, sys
m = sys.stdin.read().strip()
parts = []
for w in m.split():
    clean = re.sub(r'[^a-zA-Z0-9]', '', w)
    if not clean:
        continue
    parts.append(clean[0] if clean[0].isalpha() else clean)
print(''.join(parts), end='')
" 2>/dev/null)
[ -z "$model_short" ] && model_short="$model"

# Directory: last 2 path components
dir_segment=""
if [ -n "$cwd" ]; then
  dir_segment=$(echo "$cwd" | awk -F'/' '{if(NF>=2) print $(NF-1)"/"$NF; else print $NF}')
fi

# Context usage with color-coded urgency
ctx_segment=""
if [ -n "$used_pct" ]; then
  pct_int=$(printf '%.0f' "$used_pct")
  if [ "$pct_int" -ge 80 ]; then
    ctx_color=$'\033[38;5;203m'   # red when high
  elif [ "$pct_int" -ge 50 ]; then
    ctx_color=$'\033[38;5;215m'   # orange when mid
  else
    ctx_color="$C_CTX"           # green when low
  fi
  ctx_segment="${ctx_color}${pct_int}%ctx${C_RESET}"
fi

# Rate limits
rate_segment=""
if [ -n "$five_hour" ]; then
  rate_segment="${C_RATE}5h:$(printf '%.0f' "$five_hour")%${C_RESET}"
fi
if [ -n "$seven_day" ]; then
  week_part="${C_RATE}7d:$(printf '%.0f' "$seven_day")%${C_RESET}"
  if [ -n "$rate_segment" ]; then
    rate_segment="$rate_segment $week_part"
  else
    rate_segment="$week_part"
  fi
fi

# Session cost
cost_segment=""
if [ -n "$cost" ]; then
  cost_segment="${C_COST}$(printf '$%.3f' "$cost" 2>/dev/null)${C_RESET}"
fi

# Custom context via Python helper
# Output: line 1 = "EMOJI\tNAME\t", subsequent lines = one PR/ticket per line
emoji=""
session_name=""
extra_lines=""
ctx_file="/tmp/claude-custom-context-${session_id:-$PPID}.json"
ctx_out=$(python3 "${HOME}/.claude/statusline-context.py" "$ctx_file" "$session_id" "$cwd" 2>/dev/null)
if [ -n "$ctx_out" ]; then
  first_line=$(printf '%s' "$ctx_out" | head -1)
  emoji=$(printf '%s' "$first_line" | cut -f1)
  session_name=$(printf '%s' "$first_line" | cut -f2)
  extra_lines=$(printf '%s' "$ctx_out" | tail -n +2)
fi

# --- Line 1: [emoji] name · model · dir · ctx · cost · rate ---
C_NAME=$'\033[38;5;183m'   # soft lavender for name
line1=""
if [ -n "$emoji" ] && [ -n "$session_name" ]; then
  line1="${emoji}  ${C_NAME}${session_name}${C_RESET}"
elif [ -n "$session_name" ]; then
  line1="${C_NAME}${session_name}${C_RESET}"
fi
[ -n "$model_short" ]  && { [ -n "$line1" ] && line1="${line1}${SEP}"; line1="${line1}${C_MODEL}${model_short}${C_RESET}"; }
[ -n "$dir_segment" ]  && line1="${line1}${SEP}${C_DIR}${dir_segment}${C_RESET}"
[ -n "$ctx_segment" ]  && line1="${line1}${SEP}${ctx_segment}"
[ -n "$cost_segment" ] && line1="${line1}${SEP}${cost_segment}"
[ -n "$rate_segment" ] && line1="${line1}${SEP}${rate_segment}"

printf '%s\n' "$line1"
[ -n "$extra_lines" ] && printf '%s' "$extra_lines"
exit 0
