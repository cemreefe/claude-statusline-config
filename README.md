# claude-statusline-config

A rich status bar and session context system for [Claude Code](https://claude.ai/code).

![status bar showing emoji, name, model, directory, context %, cost, and PR lines with gradient colors](https://github.com/cemreefe/claude-statusline-config/raw/main/docs/preview.png)

## What it does

**Status bar line 1:** `🧿 Nazar · S46 · project/dir · 19%ctx · $0.379`

- Session emoji and name (random, persistent across reboots)
- Model shorthand (e.g. `S46` for Sonnet 4.6)
- Last 2 path components of the working directory
- Context window usage (color shifts yellow > red as it fills)
- Session cost in USD
- Rate limit usage (5h / 7d) when active

**Status bar line 2+:** one line per open PR

- `#503060 TRAVEL-8988 block car bookings when delegate session drops`
- PR number rendered as a **24-bit color gradient**: left side = CI status, right side = review status
- Green = passing/approved, yellow = pending/review required, red = failing/changes requested, purple = merged
- Ticket IDs extracted from PR titles, colored by project key, linked to your issue tracker
- PR titles cleaned of conventional commit prefixes (`fix:`, `feat(scope):`, etc.)
- PR status cached for 120s to avoid rate limits

**Hooks:**

- `SessionStart`: assigns a random name and emoji to each session, persisted across reboots
- `PostToolUse`: scans all tool output for GitHub PR URLs and populates the status bar automatically

## Requirements

- [Claude Code](https://claude.ai/code)
- `gh` (GitHub CLI), authenticated
- `jq`
- Python 3.8+

## Install

```bash
git clone https://github.com/cemreefe/claude-statusline-config
cd claude-statusline-config
bash install.sh
```

Then restart Claude Code.

## Configure

Copy and edit the config:

```bash
# Already done by install.sh — just edit the file
$EDITOR ~/.claude/statusline-config.json
```

### `~/.claude/statusline-config.json`

```json
{
  "strip_patterns": [
    "^[a-z]+(\\([^)]*\\))?!?:\\s*"
  ],
  "ticket_patterns": [
    {
      "pattern": "[A-Z][A-Z0-9]+-\\d+",
      "url_template": "https://your-org.atlassian.net/browse/{ticket}"
    }
  ]
}
```

| Field | Description |
|---|---|
| `strip_patterns` | List of regexes applied left-to-right to clean PR titles. The default strips conventional commit prefixes (`fix(scope):`, `feat!:`, etc.). |
| `ticket_patterns` | List of `{pattern, url_template}` entries. `{ticket}` in `url_template` is replaced with the matched ID. `url_template` is optional — tickets without one display as colored text with no link. Multiple patterns are supported (Jira, Linear, GitHub issues, etc.). |

### Adding a second tracker

```json
{
  "ticket_patterns": [
    {
      "pattern": "[A-Z][A-Z0-9]+-\\d+",
      "url_template": "https://linear.app/your-org/issue/{ticket}"
    },
    {
      "pattern": "GH-\\d+",
      "url_template": "https://github.com/your-org/your-repo/issues/{ticket}"
    }
  ]
}
```

## Customising names

`~/.claude/names.txt` is a plain text file with one name per line. Edit it freely. The included list contains ~5000 English first names sourced from [dominictarr/random-name](https://github.com/dominictarr/random-name).

## File layout after install

```
~/.claude/
├── statusline-command.sh     # main status bar script (Claude Code statusLine)
├── statusline-context.py     # Python helper: renders PR lines, loads config
├── statusline-config.json    # your config (created from example on first install)
├── names.txt                 # name pool for session names
├── session-names.json        # durable store: session_id -> {name, emoji}
└── hooks/
    ├── assign-name.sh        # SessionStart hook: assign name + emoji
    └── extract-prs.py        # PostToolUse hook: auto-populate PRs from tool output
```

## How PR auto-population works

The `PostToolUse` hook fires after every tool call and scans the output for GitHub PR URLs (`https://github.com/org/repo/pull/N`). When found, it fetches the PR title via `gh` and adds it to the session context. PRs persist for the session and are deduplicated by URL and number.

## License

MIT
