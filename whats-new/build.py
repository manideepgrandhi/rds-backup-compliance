#!/usr/bin/env python3
"""Build a static What's new page from CHANGELOG.md + published GitHub releases."""
from __future__ import annotations

import html
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

IST = timezone(timedelta(hours=5, minutes=30))


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def run(cmd: list[str]) -> str:
    p = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return p.stdout


def parse_changelog(path: Path) -> dict[str, list[str]]:
    """Return { '1.6.0': [bullets...] } from CHANGELOG.md."""
    text = path.read_text(encoding="utf-8")
    versions: dict[str, list[str]] = {}
    current: str | None = None
    for line in text.splitlines():
        m = re.match(r"^##\s+[vV]?(\d+\.\d+\.\d+)\s*$", line.strip())
        if m:
            current = m.group(1)
            versions.setdefault(current, [])
            continue
        if current is None:
            continue
        bm = re.match(r"^[-*]\s+(.+)$", line.strip())
        if bm:
            versions[current].append(bm.group(1).strip())
    return versions


def gh_releases(owner: str, repo: str) -> list[dict]:
    raw = run(
        [
            "gh",
            "release",
            "list",
            "-R",
            f"{owner}/{repo}",
            "--limit",
            "100",
            "--json",
            "tagName,isLatest,publishedAt,name",
        ]
    )
    return json.loads(raw)


def gh_assets(owner: str, repo: str, tag: str) -> list[str]:
    raw = run(
        [
            "gh",
            "release",
            "view",
            tag,
            "-R",
            f"{owner}/{repo}",
            "--json",
            "assets",
        ]
    )
    assets = json.loads(raw).get("assets") or []
    return [a["name"] for a in assets]


def to_ist(iso: str) -> str:
    dt = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(IST)
    return dt.strftime("%d %b %Y, %I:%M %p IST")


def build(repo_root: Path) -> None:
    owner = os.environ.get("GITHUB_OWNER", "manideepgrandhi")
    repo = os.environ.get("GITHUB_REPO") or repo_root.name
    zip_name = f"{repo}.zip"
    sha_name = f"{repo}.zip.sha256"

    changelog = repo_root / "CHANGELOG.md"
    if not changelog.is_file():
        die(f"missing {changelog}")

    src_dir = repo_root / "whats-new"
    dist = src_dir / "dist"
    dist.mkdir(parents=True, exist_ok=True)

    features = parse_changelog(changelog)
    releases = gh_releases(owner, repo)
    if not releases:
        die(f"no published releases for {owner}/{repo}")

    cards = []
    for rel in releases:
        tag = rel["tagName"]
        ver = tag.lstrip("vV")
        bullets = features.get(ver) or []
        if not bullets:
            # still show the release, with a fallback bullet
            bullets = [f"See the release notes for {tag}."]
        names = gh_assets(owner, repo, tag)
        has_zip = zip_name in names
        has_sha = sha_name in names
        base = f"https://github.com/{owner}/{repo}/releases/download/{tag}"
        notes = f"https://github.com/{owner}/{repo}/releases/tag/{tag}"
        cards.append(
            {
                "tag": tag,
                "ver": ver,
                "latest": bool(rel.get("isLatest")),
                "date_ist": to_ist(rel["publishedAt"]),
                "published_at": rel["publishedAt"],
                "bullets": bullets,
                "zip_url": f"{base}/{zip_name}" if has_zip else None,
                "sha_url": f"{base}/{sha_name}" if has_sha else None,
                "notes_url": notes,
            }
        )

    # newest first already from gh release list
    title = f"What's new · {repo}"
    desc = (
        f"Features added in each published release of {repo}. "
        "Download the zip for any version."
    )

    card_html = []
    for c in cards:
        search = " ".join(
            [c["ver"], c["tag"], c["date_ist"]] + c["bullets"]
        ).lower()
        badge = '<span class="badge">Latest</span>' if c["latest"] else ""
        feats = "\n".join(
            f'          <li>{html.escape(b)}</li>' for b in c["bullets"]
        )
        actions = []
        if c["zip_url"]:
            actions.append(
                f'<a class="btn primary" href="{html.escape(c["zip_url"])}">Download zip</a>'
            )
        if c["sha_url"]:
            actions.append(
                f'<a class="btn" href="{html.escape(c["sha_url"])}">sha256</a>'
            )
        actions.append(
            f'<a class="btn" href="{html.escape(c["notes_url"])}">Release notes</a>'
        )
        card_html.append(
            f'''    <article class="card" data-search="{html.escape(search)}">
      <div class="card-top">
        <span class="ver">{html.escape(c["tag"])}</span>
        {badge}
        <span class="date">{html.escape(c["date_ist"])}</span>
      </div>
      <ul class="features">
{feats}
      </ul>
      <div class="actions">
        {" ".join(actions)}
      </div>
    </article>'''
        )

    page = f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="description" content="{html.escape(desc)}" />
  <meta name="theme-color" content="#f7f8fa" />
  <title>{html.escape(title)}</title>
  <link rel="stylesheet" href="./style.css" />
</head>
<body>
  <div class="wrap">
    <header class="site-header">
      <a class="brand" href="https://github.com/{html.escape(owner)}/{html.escape(repo)}"><span>{html.escape(repo)}</span></a>
      <nav class="nav">
        <a href="https://github.com/{html.escape(owner)}/{html.escape(repo)}">Repository</a>
        <a href="https://github.com/{html.escape(owner)}/{html.escape(repo)}#readme">README</a>
        <a href="https://github.com/{html.escape(owner)}/{html.escape(repo)}/releases">All releases</a>
      </nav>
    </header>

    <section class="hero">
      <p class="eyebrow">Release history</p>
      <h1>What&rsquo;s new</h1>
      <p class="lede">{html.escape(desc)}</p>
      <div class="toolbar">
        <label class="visually-hidden" for="q" style="position:absolute;left:-9999px">Search features</label>
        <input id="q" type="search" placeholder="Search features, versions…" autocomplete="off" />
      </div>
      <p class="meta-line"><span id="count"></span> · times in IST (Asia/Calcutta)</p>
    </section>

    <div id="list" class="list">
{chr(10).join(card_html)}
    </div>
    <p id="empty" class="empty">No releases match that search.</p>

    <footer class="site-footer">
      Built from <code>CHANGELOG.md</code> and published GitHub releases.
      Source: <a href="https://github.com/{html.escape(owner)}/{html.escape(repo)}">github.com/{html.escape(owner)}/{html.escape(repo)}</a>
    </footer>
  </div>
  <script src="./app.js"></script>
</body>
</html>
'''

    (dist / "index.html").write_text(page, encoding="utf-8")
    for name in ("style.css", "app.js"):
        src = src_dir / name
        if not src.is_file():
            die(f"missing {src}")
        (dist / name).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")

    meta = {
        "repo": repo,
        "owner": owner,
        "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "releases": [
            {
                "tag": c["tag"],
                "date_ist": c["date_ist"],
                "latest": c["latest"],
                "zip": c["zip_url"],
                "sha256": c["sha_url"],
                "features": c["bullets"],
            }
            for c in cards
        ],
    }
    (dist / "releases.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="utf-8"
    )
    print(f"built {dist}/index.html with {len(cards)} releases")


if __name__ == "__main__":
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
    build(root)
