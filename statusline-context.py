#!/usr/bin/env python3
"""
Reads /tmp/claude-custom-context-<session-id>.json and prints status line content.

PR numbers are rendered with a 24-bit color gradient:
  left  = CI/build status color
  right = review/approval status color

Status is cached per-PR in the context JSON (TTL 120s) to avoid fetching on
every statusline render.

Output format:
  Line 1:  EMOJI\tNAME\t\n   (shell splits on tabs)
  Line 2+: one line per PR / ticket
"""
import json
import os
import random
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional

STATUS_TTL = 120  # default seconds before re-fetching PR status; override in config

_COLORS: dict[str, tuple[int, int, int]] = {
    "passing":             (70, 210, 110),  # green
    "approved":            (70, 210, 110),  # green
    "failing":             (220, 70,  70),  # red
    "changes_requested":   (220, 70,  70),  # red
    "pending":             (200, 155, 50),  # yellow
    "review_required":     (200, 155, 50),  # yellow
    "merged":              (160, 90, 220),  # purple
    "unknown":             (110, 110, 110), # grey
}

CI_COLORS = _COLORS
REVIEW_COLORS = _COLORS


def strip_title(text: str) -> str:
    """Apply all configured strip_patterns to a PR title."""
    for pat in _CONFIG.get("strip_patterns", []):
        try:
            text = re.sub(pat, '', text, flags=re.IGNORECASE).strip()
        except re.error:
            pass
    return text


# Deterministic per-project color from a small palette of readable 24-bit colors
_TICKET_PALETTE = [
    (100, 180, 255),  # sky blue
    (180, 130, 255),  # violet
    (255, 180, 80),   # gold
    (80,  210, 200),  # teal
    (255, 130, 160),  # rose
    (130, 220, 130),  # mint
]

def ticket_color(project: str) -> tuple[int, int, int]:
    return _TICKET_PALETTE[hash(project) % len(_TICKET_PALETTE)]


def load_config() -> dict:
    """Load optional user config from ~/.claude/statusline-config.json."""
    try:
        path = os.path.expanduser("~/.claude/statusline-config.json")
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


_CONFIG: dict = {}          # populated in main()
_TICKET_PATTERNS: list = [] # compiled once in main() after config is loaded


def _compile_ticket_patterns() -> list[tuple[re.Pattern, str]]:
    result = []
    for entry in _CONFIG.get("ticket_patterns", []):
        pat = entry.get("pattern", "")
        url_tpl = entry.get("url_template", "")
        if not pat:
            continue
        try:
            result.append((re.compile(r'\b(' + pat + r')\b'), url_tpl))
        except re.error:
            pass
    return result


def extract_tickets(text: str) -> list[str]:
    """Return deduplicated ticket IDs found in text, across all configured patterns."""
    seen: dict[str, None] = {}
    for compiled, _ in _TICKET_PATTERNS:
        for m in compiled.finditer(text):
            seen[m.group(1)] = None
    return list(seen)


def ticket_url(tid: str) -> str:
    """Return the URL for a ticket ID, or empty string if no matching pattern has a url_template."""
    for compiled, url_tpl in _TICKET_PATTERNS:
        if compiled.search(tid) and url_tpl:
            return url_tpl.replace("{ticket}", tid)
    return ""


def strip_tickets(text: str) -> str:
    """Remove all configured ticket references including surrounding brackets/parens."""
    for compiled, _ in _TICKET_PATTERNS:
        text = re.sub(r'[\(\[]\s*' + compiled.pattern.strip(r'\b()') + r'\s*[\)\]]', '', text)
        text = compiled.sub('', text)
    return re.sub(r'\s{2,}', ' ', text).strip(' -\u2013()[]')


def render_ticket_prefix(tickets: list[str]) -> str:
    """Render tickets as colored links (or plain text) before the PR title."""
    parts = []
    for tid in tickets:
        project = tid.split("-")[0]
        r, g, b = ticket_color(project)
        url = ticket_url(tid)
        if url:
            parts.append(f"\033[38;2;{r};{g};{b}m\033]8;;{url}\033\\{tid}\033]8;;\033\\\033[0m")
        else:
            parts.append(f"\033[38;2;{r};{g};{b}m{tid}\033[0m")
    return " ".join(parts)


def link(url: str, text: str) -> str:
    """OSC 8 hyperlink, no extra ANSI color (gradient on the number handles color)."""
    return f"\033]8;;{url}\033\\{text}\033]8;;\033\\"


def gradient_text(text: str, left: tuple[int, int, int], right: tuple[int, int, int]) -> str:
    n = len(text)
    out = ""
    for i, ch in enumerate(text):
        t = i / max(n - 1, 1)
        r = int(left[0] + t * (right[0] - left[0]))
        g = int(left[1] + t * (right[1] - left[1]))
        b = int(left[2] + t * (right[2] - left[2]))
        out += f"\033[38;2;{r};{g};{b}m{ch}"
    return out + "\033[0m"


def run_cmd(cmd: list, cwd: Optional[str] = None) -> str:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=8, cwd=cwd)
        return r.stdout.strip()
    except Exception:
        return ""


def fetch_pr_status(number: int, repo: str) -> dict:
    """Returns {"ci": "passing"|"failing"|"pending"|"unknown",
                "review": "approved"|"changes_requested"|"review_required"|"unknown"}"""
    raw = run_cmd([
        "gh", "pr", "view", str(number),
        "--repo", repo,
        "--json", "reviewDecision,statusCheckRollup,state",
    ])
    ci = "unknown"
    review = "unknown"
    if raw:
        try:
            d = json.loads(raw)

            # CI status: aggregate statusCheckRollup
            # Merged PRs passed CI by definition
            if (d.get("state") or "").upper() == "MERGED":
                ci = "merged"
            else:
                checks = d.get("statusCheckRollup") or []
                states: set[str] = set()
                for c in checks:
                    if not isinstance(c, dict):
                        continue
                    typename = c.get("__typename", "")
                    if typename == "StatusContext":
                        # Buildkite and other commit statuses
                        s = c.get("state", "").upper()
                        if s:
                            states.add(s)
                    elif typename == "CheckRun":
                        status = c.get("status", "").upper()
                        conclusion = c.get("conclusion", "").upper()
                        name = c.get("name", "")
                        # Skip review-gating checks — they reflect approval, not CI
                        if "review" in name.lower():
                            continue
                        if status in ("IN_PROGRESS", "QUEUED", "WAITING"):
                            states.add("PENDING")
                        elif conclusion:
                            states.add(conclusion)
                if not states:
                    ci = "unknown"
                elif states & {"FAILURE", "ERROR", "CANCELLED"}:
                    ci = "failing"
                elif states & {"PENDING"}:
                    ci = "pending"
                else:
                    ci = "passing"

            # Review decision
            if (d.get("state") or "").upper() == "MERGED":
                review = "merged"
            else:
                rd = (d.get("reviewDecision") or "").upper()
                if rd == "APPROVED":
                    review = "approved"
                elif rd == "CHANGES_REQUESTED":
                    review = "changes_requested"
                elif rd == "REVIEW_REQUIRED":
                    review = "review_required"

        except Exception:
            pass
    return {"ci": ci, "review": review}


def get_branch(cwd: Optional[str] = None) -> str:
    return run_cmd(
        ["git", "-c", "core.hooksPath=/dev/null", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=cwd,
    )


def get_open_prs(branch: str) -> list:
    raw = run_cmd([
        "gh", "pr", "list",
        "--head", branch,
        "--state", "open",
        "--json", "number,title,url,repository",
        "--limit", "3",
    ])
    if not raw:
        return []
    try:
        prs = json.loads(raw)
        return prs if isinstance(prs, list) else []
    except Exception:
        return []


def main() -> None:
    global _CONFIG, _TICKET_PATTERNS
    _CONFIG = load_config()
    _TICKET_PATTERNS = _compile_ticket_patterns()

    ctx_file = sys.argv[1] if len(sys.argv) > 1 else ""
    seed = sys.argv[2] if len(sys.argv) > 2 else str(os.getppid())
    git_cwd = sys.argv[3] if len(sys.argv) > 3 else None

    data: dict = {}
    if ctx_file:
        try:
            with open(ctx_file) as f:
                data = json.load(f)
        except Exception:
            pass

    # If name/emoji missing from /tmp/ file (e.g. after reboot), restore from durable store
    if not data.get("name") or not data.get("emoji"):
        names_db = os.path.expanduser("~/.claude/session-names.json")
        try:
            with open(names_db) as f:
                db = json.load(f)
            entry = db.get(seed, {})
            if not data.get("name") and entry.get("name"):
                data["name"] = entry["name"]
            if not data.get("emoji") and entry.get("emoji"):
                data["emoji"] = entry["emoji"]
            # Recreate the /tmp/ file so future renders don't need the fallback
            if ctx_file and (data.get("name") or data.get("emoji")):
                try:
                    with open(ctx_file, "w") as f:
                        json.dump(data, f, indent=2)
                except Exception:
                    pass
        except Exception:
            pass

    emoji = data.get("emoji") or chr(random.Random(seed).randint(0x1F300, 0x1F9FF))
    name = data.get("name", "")
    print(f"{emoji}\t{name}\t", end="\n")

    manual_prs = data.get("prs", [])
    manual_tickets = data.get("tickets", [])

    # Auto-detect from branch when no manual PRs
    auto_prs: list = []
    branch = get_branch(cwd=git_cwd)
    if not manual_prs and branch and branch not in ("HEAD", ""):
        for p in get_open_prs(branch):
            repo_info = p.get("repository", {})
            auto_prs.append({
                "number": p["number"],
                "title": p.get("title", f"#{p['number']}"),
                "url": p.get("url", ""),
                "repo": repo_info.get("nameWithOwner", ""),
            })

    prs_to_render = manual_prs if manual_prs else auto_prs
    now = time.time()
    ttl = _CONFIG.get("status_ttl", STATUS_TTL)
    ctx_dirty = False

    # Fetch stale statuses in parallel
    stale = [p for p in prs_to_render if now - p.get("status_at", 0) > ttl]
    if stale:
        with ThreadPoolExecutor(max_workers=len(stale)) as ex:
            futures = {ex.submit(fetch_pr_status, p["number"], p.get("repo", "")): p for p in stale}
            for future in as_completed(futures):
                p = futures[future]
                try:
                    status = future.result()
                except Exception:
                    status = {"ci": "unknown", "review": "unknown"}
                p["ci"] = status["ci"]
                p["review"] = status["review"]
                p["status_at"] = now
                ctx_dirty = True

    for p in prs_to_render:
        repo = p.get("repo", "")
        number = p["number"]
        url = p.get("url") or f"https://github.com/{repo}/pull/{number}"
        ci_color = CI_COLORS.get(p.get("ci", "unknown"), CI_COLORS["unknown"])
        review_color = REVIEW_COLORS.get(p.get("review", "unknown"), REVIEW_COLORS["unknown"])
        num_str = gradient_text(f"#{number}", ci_color, review_color)
        raw_title = p.get("title", f"#{number}")
        tickets = extract_tickets(raw_title)
        clean_title = strip_tickets(strip_title(raw_title))
        ticket_str = render_ticket_prefix(tickets)
        line = f"{num_str} {ticket_str} {link(url, clean_title)}" if ticket_str else f"{num_str} {link(url, clean_title)}"
        print(line)

    # Persist updated statuses back to context file
    if ctx_dirty and ctx_file and prs_to_render is manual_prs:
        try:
            with open(ctx_file, "w") as f:
                json.dump(data, f, indent=2)
        except Exception:
            pass

    dim = "\033[2m"
    reset = "\033[0m"
    for t in manual_tickets:
        tid = t["id"]
        label = strip_title(t.get("title", tid))
        url = ticket_url(tid)
        if url:
            print(f"{dim}{tid}{reset} {link(url, label)}")
        else:
            print(f"{dim}{tid}{reset} {label}")


main()
