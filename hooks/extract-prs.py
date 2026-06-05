#!/usr/bin/env python3
"""
PostToolUse hook: scans Bash tool output for GitHub PR URLs and gh JSON,
then merges any discovered PRs into the session context JSON.
"""
import json
import os
import re
import sys

# Match https://github.com/ORG/REPO/pull/NUMBER
PR_URL_RE = re.compile(r'https://github\.com/([^/]+/[^/]+)/pull/(\d+)')

def find_context_file(session_id: str) -> str:
    return f"/tmp/claude-custom-context-{session_id}.json"


def load_context(path: str) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def save_context(path: str, data: dict) -> None:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def load_strip_patterns() -> list[str]:
    try:
        path = os.path.expanduser("~/.claude/statusline-config.json")
        with open(path) as f:
            cfg = json.load(f)
        return cfg.get("strip_patterns", [])
    except Exception:
        return []


def strip_title(title: str) -> str:
    for pat in load_strip_patterns():
        try:
            title = re.sub(pat, '', title, flags=re.IGNORECASE).strip()
        except re.error:
            pass
    return title


def main() -> None:
    hook_input = json.load(sys.stdin)

    output = hook_input.get("tool_response", {})
    if isinstance(output, dict):
        stdout = output.get("stdout", "") or ""
        stderr = output.get("stderr", "") or ""
        text = stdout + "\n" + stderr
    else:
        text = str(output) if output else ""

    if not text.strip():
        return

    found: dict[str, dict] = {}  # url -> pr dict

    # 1. Try to parse as JSON array (gh --json output or MCP response)
    for chunk in [text]:
        try:
            data = json.loads(chunk.strip())
            if isinstance(data, list):
                for item in data:
                    if not isinstance(item, dict):
                        continue
                    url = item.get("url", "")
                    number = item.get("number")
                    title = item.get("title", "")
                    repo_info = item.get("repository", {})
                    if isinstance(repo_info, dict):
                        repo = repo_info.get("nameWithOwner", "")
                    else:
                        repo = ""
                    if url and number:
                        m = PR_URL_RE.match(url)
                        if m and not repo:
                            repo = m.group(1)
                        found[url] = {
                            "number": number,
                            "title": strip_title(title),
                            "url": url,
                            "repo": repo,
                        }
        except Exception:
            pass

    # 2. Scan raw text for PR URLs — fetch title via gh if not already known
    for m in PR_URL_RE.finditer(text):
        url = m.group(0)
        repo = m.group(1)
        number = int(m.group(2))
        if url not in found:
            # Try to fetch real title
            title = f"#{number}"
            try:
                import subprocess as _sp
                r = _sp.run(
                    ["gh", "pr", "view", str(number), "--repo", repo, "--json", "title", "--jq", ".title"],
                    capture_output=True, text=True, timeout=5,
                )
                if r.returncode == 0 and r.stdout.strip():
                    title = strip_title(r.stdout.strip())
            except Exception:
                pass
            found[url] = {
                "number": number,
                "title": title,
                "url": url,
                "repo": repo,
            }

    if not found:
        return

    session_id = hook_input.get("session_id", "")
    if not session_id:
        return
    ctx_path = find_context_file(session_id)
    if not ctx_path:
        # Create it
        ppid = os.getppid()
        ctx_path = f"/tmp/claude-custom-context-{ppid}.json"

    ctx = load_context(ctx_path)
    existing_prs: list = ctx.get("prs", [])
    existing_urls = {p.get("url") for p in existing_prs}
    existing_numbers = {p.get("number") for p in existing_prs}

    added = False
    for pr in found.values():
        if pr["url"] not in existing_urls and pr["number"] not in existing_numbers:
            existing_prs.append(pr)
            added = True

    if added:
        ctx["prs"] = existing_prs
        save_context(ctx_path, ctx)


main()
