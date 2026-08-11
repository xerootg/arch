#!/usr/bin/env python3
"""Generate the package index published on the GitHub Pages site.

The input is the pacman database of each repo -- the `.db` tarball that
`repo-add` writes at the end of every build. Nothing here is hand-maintained
and nothing had to be bolted onto the builder: that database already carries
the name, version, description, URL, licence, sizes and `%BUILDDATE%` of every
package, and it is the same file pacman itself downloads, so the page can never
disagree with what a client would install.

State lives in CSVs in the Pages repo and is the only thing that persists
between runs. They start empty and are built up over time:

  data/packages.csv  one row per (repo, package), current contents
  data/changes.csv   append-only log of adds, updates and removals
  data/state.json    last check time, and a digest used to avoid empty commits

The `.db` is a snapshot with no history, so "when was this added" cannot be
recovered from it -- that is what packages.csv is for. `first_seen_utc` is
recorded the first time a package is observed and never rewritten afterwards.

Rendering reads *only* the CSVs, never the databases. That is deliberate: a
repo whose database could not be fetched this run (a release download that
502'd, say) keeps its last known contents on the page instead of silently
emptying out, and no spurious "removed" events get logged for it.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import tarfile
from datetime import datetime, timezone

PACKAGE_FIELDS = [
    "repo",
    "pkgname",
    "pkgver",
    "arch",
    "description",
    "url",
    "licenses",
    "download_bytes",
    "installed_bytes",
    "built_utc",
    "first_seen_utc",
    "last_updated_utc",
    "filename",
]

CHANGE_FIELDS = [
    "timestamp_utc",
    "repo",
    "pkgname",
    "event",
    "from_version",
    "to_version",
]

# Keep the changelog bounded. At a handful of events per week this is decades
# of history, and it stops a pathological loop from growing the file forever.
MAX_CHANGES = 5000

# How many entries the rendered page shows. The full log stays in the CSV.
SHOWN_CHANGES = 60

# Re-commit an unchanged index after this long, so "last checked" on the page
# does not go stale. Without it the page would only ever be touched when a
# package moved, and a quiet month would look like a month of downtime.
STALE_AFTER_SECONDS = 20 * 60 * 60


# --------------------------------------------------------------------------
# pacman database
# --------------------------------------------------------------------------


def parse_db(path: str) -> dict[str, dict[str, list[str]]]:
    """Read a repo-add database into {entry_dir: {FIELD: [values]}}.

    The format is one directory per package holding a `desc` file (and in a
    `.files` database, a `files` file too) of `%FIELD%` headers, each followed
    by one value per line and terminated by a blank line. Every file in the
    entry is parsed and merged, so this works on both database flavours.
    """
    entries: dict[str, dict[str, list[str]]] = {}
    with tarfile.open(path, "r:*") as tf:
        for member in tf.getmembers():
            if not member.isfile():
                continue
            entry = member.name.split("/")[0]
            if not entry or entry == member.name:
                continue
            handle = tf.extractfile(member)
            if handle is None:
                continue
            fields = entries.setdefault(entry, {})
            current: str | None = None
            for line in handle.read().decode("utf-8", "replace").splitlines():
                if line.startswith("%") and line.endswith("%") and len(line) > 2:
                    current = line[1:-1]
                    fields.setdefault(current, [])
                elif not line.strip():
                    current = None
                elif current is not None:
                    fields[current].append(line)
    return entries


def first(fields: dict[str, list[str]], key: str, default: str = "") -> str:
    values = fields.get(key) or []
    return values[0] if values else default


def db_to_rows(repo: str, entries: dict[str, dict[str, list[str]]]) -> dict[str, dict]:
    """Flatten one database into {pkgname: row}, in packages.csv's shape."""
    rows: dict[str, dict] = {}
    for fields in entries.values():
        name = first(fields, "NAME")
        if not name:
            continue
        built = first(fields, "BUILDDATE")
        rows[name] = {
            "repo": repo,
            "pkgname": name,
            "pkgver": first(fields, "VERSION"),
            "arch": first(fields, "ARCH"),
            "description": first(fields, "DESC"),
            "url": first(fields, "URL"),
            "licenses": " ".join(fields.get("LICENSE") or []),
            "download_bytes": first(fields, "CSIZE", "0"),
            "installed_bytes": first(fields, "ISIZE", "0"),
            "built_utc": epoch_to_utc(built),
            "filename": first(fields, "FILENAME"),
        }
    return rows


# --------------------------------------------------------------------------
# time and formatting
# --------------------------------------------------------------------------


def signing_fingerprint(sig_path: str) -> str:
    """Read the issuer fingerprint out of a detached signature.

    Taken from the signature rather than from config or from the key file,
    because this is the one source that cannot drift: it is whatever key
    actually signed the database clients download. No secret is needed -- the
    issuer is in the cleartext of the signature packet.
    """
    try:
        result = subprocess.run(
            ["gpg", "--list-packets", sig_path],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    match = re.search(r"issuer fpr v4 ([0-9A-Fa-f]{40})", result.stdout)
    if match:
        return match.group(1).upper()
    # Older signatures carry only the 64-bit key id.
    match = re.search(r"keyid ([0-9A-Fa-f]{16})", result.stdout)
    return match.group(1).upper() if match else ""


def epoch_to_utc(value: str) -> str:
    try:
        return (
            datetime.fromtimestamp(int(value), tz=timezone.utc)
            .strftime("%Y-%m-%dT%H:%M:%SZ")
        )
    except (TypeError, ValueError):
        return ""


def day(stamp: str) -> str:
    """Trim an ISO timestamp to a date for display."""
    return stamp[:10] if stamp else "—"


def human_bytes(value: str) -> str:
    try:
        size = float(value)
    except (TypeError, ValueError):
        return "—"
    for unit in ("B", "KiB", "MiB", "GiB"):
        if size < 1024 or unit == "GiB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return "—"


# --------------------------------------------------------------------------
# persisted state
# --------------------------------------------------------------------------


def read_csv(path: str, fieldnames: list[str]) -> list[dict]:
    if not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    # Tolerate a file written by an older column set: fill in what is missing
    # rather than dying, so adding a column never needs a manual migration.
    return [{key: row.get(key, "") or "" for key in fieldnames} for row in rows]


def write_csv(path: str, fieldnames: list[str], rows: list[dict]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})


# --------------------------------------------------------------------------
# reconciliation
# --------------------------------------------------------------------------


def reconcile(
    known: list[dict],
    observed: dict[str, dict[str, dict]],
    available: set[str],
    now: str,
    seeding: bool,
) -> tuple[list[dict], list[dict]]:
    """Fold this run's databases into the known package rows.

    `observed` is {repo: {pkgname: row}} and `available` names the repos whose
    database was actually read. Repos outside it are passed through untouched.
    """
    by_key = {(row["repo"], row["pkgname"]): row for row in known}
    events: list[dict] = []

    for repo in sorted(available):
        rows = observed.get(repo, {})

        for pkgname, fresh in sorted(rows.items()):
            key = (repo, pkgname)
            previous = by_key.get(key)
            if previous is None:
                # A package's history predates this tool, so the seed run
                # records the baseline rather than claiming everything in the
                # repo was added the moment the tool first ran.
                fresh["first_seen_utc"] = now
                fresh["last_updated_utc"] = now
                by_key[key] = fresh
                events.append(
                    {
                        "timestamp_utc": now,
                        "repo": repo,
                        "pkgname": pkgname,
                        "event": "seeded" if seeding else "added",
                        "from_version": "",
                        "to_version": fresh["pkgver"],
                    }
                )
                continue

            old_version = previous["pkgver"]
            fresh["first_seen_utc"] = previous["first_seen_utc"] or now
            if old_version != fresh["pkgver"]:
                fresh["last_updated_utc"] = now
                events.append(
                    {
                        "timestamp_utc": now,
                        "repo": repo,
                        "pkgname": pkgname,
                        "event": "updated",
                        "from_version": old_version,
                        "to_version": fresh["pkgver"],
                    }
                )
            else:
                fresh["last_updated_utc"] = previous["last_updated_utc"] or now
            by_key[key] = fresh

        for (row_repo, pkgname), row in list(by_key.items()):
            if row_repo == repo and pkgname not in rows:
                del by_key[(row_repo, pkgname)]
                events.append(
                    {
                        "timestamp_utc": now,
                        "repo": repo,
                        "pkgname": pkgname,
                        "event": "removed",
                        "from_version": row["pkgver"],
                        "to_version": "",
                    }
                )

    packages = sorted(by_key.values(), key=lambda row: (row["repo"], row["pkgname"]))
    return packages, events


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

STYLE = """
:root {
  color-scheme: light dark;
  --bg: #ffffff;
  --panel: #f6f8fa;
  --panel-border: #d8dee4;
  --text: #1f2328;
  --muted: #59636e;
  --accent: #0969da;
  --code-bg: #f0f3f6;
  --row-hover: #f0f3f6;
  --added: #1a7f37;
  --updated: #9a6700;
  --removed: #cf222e;
  --seeded: #59636e;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0d1117;
    --panel: #151b23;
    --panel-border: #3d444d;
    --text: #e6edf3;
    --muted: #9198a1;
    --accent: #4493f8;
    --code-bg: #151b23;
    --row-hover: #151b23;
    --added: #3fb950;
    --updated: #d29922;
    --removed: #f85149;
    --seeded: #9198a1;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  padding: 2.5rem 1.25rem 5rem;
  background: var(--bg);
  color: var(--text);
  font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
}
main { max-width: 1100px; margin: 0 auto; }
h1 { font-size: 2rem; margin: 0 0 .35rem; letter-spacing: -.02em; }
h2 { font-size: 1.3rem; margin: 2.75rem 0 .5rem; letter-spacing: -.01em; }
h2 code { font-size: 1.15rem; }
p { margin: .5rem 0; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
.tagline { color: var(--muted); margin-bottom: 1.25rem; max-width: 62ch; }
.stamps {
  display: flex; flex-wrap: wrap; gap: .5rem 1.5rem;
  padding: .75rem 1rem; margin: 0 0 2rem;
  background: var(--panel); border: 1px solid var(--panel-border); border-radius: 6px;
  font-size: .875rem;
}
.stamps div { display: flex; gap: .4rem; }
.stamps .label { color: var(--muted); }
.stamps .value { font-variant-numeric: tabular-nums; }
.note { color: var(--muted); font-size: .925rem; max-width: 78ch; }
code, pre {
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
}
code { background: var(--code-bg); padding: .12em .35em; border-radius: 4px; font-size: .875em; }
pre {
  position: relative;
  background: var(--panel); border: 1px solid var(--panel-border);
  border-radius: 6px; padding: 1rem; overflow-x: auto;
  font-size: .85rem; line-height: 1.55; margin: .75rem 0;
}
pre code { background: none; padding: 0; font-size: inherit; }
.copy {
  position: absolute; top: .5rem; right: .5rem;
  background: var(--bg); color: var(--muted);
  border: 1px solid var(--panel-border); border-radius: 5px;
  padding: .2rem .55rem; font-size: .75rem; cursor: pointer;
}
.copy:hover { color: var(--text); }
.scroll { overflow-x: auto; margin: .9rem 0; }
table { border-collapse: collapse; width: 100%; font-size: .875rem; }
th, td { text-align: left; padding: .5rem .7rem; border-bottom: 1px solid var(--panel-border); }
th {
  font-size: .75rem; text-transform: uppercase; letter-spacing: .04em;
  color: var(--muted); font-weight: 600; white-space: nowrap;
}
tbody tr:hover { background: var(--row-hover); }
td { vertical-align: top; }
td.name { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; white-space: nowrap; }
td.ver { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; white-space: nowrap; font-size: .825rem; }
td.num { text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
td.date { white-space: nowrap; font-variant-numeric: tabular-nums; color: var(--muted); }
/* Description under the name rather than in its own column. Package names here
   run to 44 characters, and eight columns of that width pushed the last one out
   of the scroll box entirely. */
td.pkg { min-width: 24ch; }
td.pkg .pkgname {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-weight: 600; white-space: nowrap;
}
td.pkg .pkgdesc {
  color: var(--muted); font-size: .8rem; line-height: 1.45;
  margin-top: .15rem; max-width: 58ch;
}
.count { color: var(--muted); font-weight: 400; font-size: .9rem; }
.event { font-weight: 600; font-size: .8rem; text-transform: lowercase; }
.event.added { color: var(--added); }
.event.updated { color: var(--updated); }
.event.removed { color: var(--removed); }
.event.seeded { color: var(--seeded); }
.stale {
  border-left: 3px solid var(--updated); padding-left: .75rem;
  color: var(--muted); font-size: .9rem;
}
footer {
  margin-top: 3.5rem; padding-top: 1.25rem;
  border-top: 1px solid var(--panel-border);
  color: var(--muted); font-size: .85rem;
}
"""

SCRIPT = """
document.querySelectorAll('pre').forEach(function (block) {
  var button = document.createElement('button');
  button.className = 'copy';
  button.type = 'button';
  button.textContent = 'copy';
  button.addEventListener('click', function () {
    navigator.clipboard.writeText(block.querySelector('code').textContent).then(function () {
      button.textContent = 'copied';
      setTimeout(function () { button.textContent = 'copy'; }, 1200);
    });
  });
  block.appendChild(button);
});
"""


def siglevel(repo: dict) -> str:
    """Match Arch's own default once a repo is signed.

    `Required DatabaseOptional` is what stock /etc/pacman.conf uses: every
    package must carry a signature from a trusted key, and a database
    signature is verified when present. Validating the database only when
    present is also what keeps a single missed signing run from locking every
    client out of the repo.
    """
    return "Required DatabaseOptional" if repo.get("signed") else "Optional TrustAll"


def pacman_conf_block(repos: list[dict]) -> str:
    lines = []
    for repo in repos:
        lines.append(f"[{repo['name']}]")
        lines.append(f"Server = {repo['server']}")
        lines.append(f"SigLevel = {siglevel(repo)}")
        lines.append("")
    return "\n".join(lines).rstrip()


KEY_URL = "https://xerootg.github.io/xerootg.asc"


def key_import_command(fingerprint: str) -> str:
    return (
        f"curl -fsSL {KEY_URL} | sudo pacman-key --add -\n"
        f"sudo pacman-key --lsign-key {fingerprint}"
    )


def install_command(repos: list[dict], fingerprint: str) -> str:
    parts = []
    if fingerprint:
        parts.append(key_import_command(fingerprint))
        parts.append("")
    parts.append(
        "sudo tee -a /etc/pacman.conf > /dev/null <<'EOF'\n\n"
        + pacman_conf_block(repos)
        + "\nEOF\nsudo pacman -Sy"
    )
    return "\n".join(parts)


def render(config: dict, packages: list[dict], changes: list[dict],
           checked: str, fingerprint: str) -> str:
    site = config["site"]
    repos = config["repos"]
    by_repo: dict[str, list[dict]] = {}
    for row in packages:
        by_repo.setdefault(row["repo"], []).append(row)

    last_change = max((c["timestamp_utc"] for c in changes), default="")
    total_bytes = sum(int(row["download_bytes"] or 0) for row in packages)

    out: list[str] = []
    add = out.append

    add("<!doctype html>")
    add('<html lang="en">')
    add("<head>")
    add('<meta charset="utf-8">')
    add('<meta name="viewport" content="width=device-width, initial-scale=1">')
    add(f"<title>{html.escape(site['title'])}</title>")
    add(f'<meta name="description" content="{html.escape(site["tagline"])}">')
    add(f"<style>{STYLE}</style>")
    add("</head>")
    add("<body>")
    add("<main>")

    add(f"<h1>{html.escape(site['title'])}</h1>")
    add(f'<p class="tagline">{html.escape(site["tagline"])}</p>')

    add('<div class="stamps">')
    add(
        '<div><span class="label">Last checked</span>'
        f'<span class="value">{html.escape(checked.replace("T", " ").replace("Z", " UTC"))}</span></div>'
    )
    add(
        '<div><span class="label">Last change</span>'
        f'<span class="value">{html.escape(last_change.replace("T", " ").replace("Z", " UTC")) or "—"}</span></div>'
    )
    add(
        '<div><span class="label">Packages</span>'
        f'<span class="value">{len(packages)}</span></div>'
    )
    add(
        '<div><span class="label">Total download</span>'
        f'<span class="value">{human_bytes(str(total_bytes))}</span></div>'
    )
    if fingerprint:
        add(
            '<div><span class="label">Signed by</span>'
            f'<span class="value"><code>{html.escape(fingerprint[-16:])}</code></span></div>'
        )
    add("</div>")

    # --- install ---------------------------------------------------------
    signed = [r for r in repos if r.get("signed")]
    add('<h2 id="install">Adding these repos</h2>')
    if fingerprint:
        add(
            '<p class="note">Paste this into a terminal. It trusts the signing key, '
            f"appends all {len(repos)} repositories to <code>/etc/pacman.conf</code>, "
            "and refreshes the package lists.</p>"
        )
    else:
        add(
            '<p class="note">Paste this into a terminal. It appends all '
            f"{len(repos)} repositories to <code>/etc/pacman.conf</code> and refreshes "
            "the package lists.</p>"
        )
    add(f"<pre><code>{html.escape(install_command(repos, fingerprint))}</code></pre>")

    if fingerprint:
        add(
            '<p class="note"><strong>Why the key step:</strong> pacman keeps its own '
            "keyring, separate from your user GPG keyring. <code>--add</code> imports "
            "the key; <code>--lsign-key</code> is the part people miss \u2014 it signs "
            "the key locally to mark it trusted, and without it pacman still refuses "
            "every package with <em>unknown trust</em>. The fingerprint is "
            f"<code>{html.escape(fingerprint)}</code>; you can check it against "
            f'<a href="{html.escape(KEY_URL)}">the published key</a>.</p>'
        )
    add(
        '<p class="note">Or edit <code>/etc/pacman.conf</code> by hand and add whichever '
        "you want. The server URLs never change, so this is a one-time edit.</p>"
    )
    add(f"<pre><code>{html.escape(pacman_conf_block(repos))}</code></pre>")
    if signed and len(signed) != len(repos):
        unsigned = ", ".join(f"<code>[{r['name']}]</code>" for r in repos if not r.get("signed"))
        add(
            f'<p class="stale">{unsigned} is not signed yet, so it stays on '
            "<code>Optional TrustAll</code> until its next publish. The others "
            "require a valid signature on every package.</p>"
        )

    # --- per repo --------------------------------------------------------
    for repo in repos:
        name = repo["name"]
        rows = by_repo.get(name, [])
        add(f'<h2 id="{html.escape(name)}"><code>[{html.escape(name)}]</code> '
            f'<span class="count">{len(rows)} package{"" if len(rows) == 1 else "s"}</span></h2>')
        add(f'<p class="note">{repo["note"]}</p>')
        add(f"<pre><code>[{html.escape(name)}]\nServer = {html.escape(repo['server'])}"
            f"\nSigLevel = {siglevel(repo)}</code></pre>")

        if not rows:
            add('<p class="stale">Nothing recorded for this repo yet.</p>')
            continue

        add('<div class="scroll"><table>')
        add(
            "<thead><tr><th>Package</th><th>Version</th>"
            "<th>Download</th><th>Installed</th><th>Built</th>"
            "<th>First seen</th><th>Updated</th></tr></thead><tbody>"
        )
        for row in rows:
            label = html.escape(row["pkgname"])
            if row["url"]:
                label = f'<a href="{html.escape(row["url"])}">{label}</a>'
            cell = f'<div class="pkgname">{label}</div>'
            if row["description"]:
                cell += f'<div class="pkgdesc">{html.escape(row["description"])}</div>'
            add(
                "<tr>"
                f'<td class="pkg">{cell}</td>'
                f'<td class="ver">{html.escape(row["pkgver"])}</td>'
                f'<td class="num">{human_bytes(row["download_bytes"])}</td>'
                f'<td class="num">{human_bytes(row["installed_bytes"])}</td>'
                f'<td class="date">{day(row["built_utc"])}</td>'
                f'<td class="date">{day(row["first_seen_utc"])}</td>'
                f'<td class="date">{day(row["last_updated_utc"])}</td>'
                "</tr>"
            )
        add("</tbody></table></div>")

    # --- changes ---------------------------------------------------------
    recent = sorted(changes, key=lambda c: c["timestamp_utc"], reverse=True)[:SHOWN_CHANGES]
    add('<h2 id="changes">Recent changes</h2>')
    if not recent:
        add('<p class="note">No changes recorded yet.</p>')
    else:
        shown = f"{len(recent)} most recent of {len(changes)}" if len(changes) > len(recent) else f"{len(changes)}"
        add(f'<p class="note">Showing {shown}. The whole log is in '
            '<a href="data/changes.csv">data/changes.csv</a>.</p>')
        add('<div class="scroll"><table>')
        add("<thead><tr><th>When</th><th>Repo</th><th>Package</th><th>Event</th>"
            "<th>From</th><th>To</th></tr></thead><tbody>")
        for change in recent:
            event = change["event"]
            add(
                "<tr>"
                f'<td class="date">{html.escape(change["timestamp_utc"][:16].replace("T", " "))}</td>'
                f'<td class="name">{html.escape(change["repo"])}</td>'
                f'<td class="name">{html.escape(change["pkgname"])}</td>'
                f'<td><span class="event {html.escape(event)}">{html.escape(event)}</span></td>'
                f'<td class="ver">{html.escape(change["from_version"]) or "—"}</td>'
                f'<td class="ver">{html.escape(change["to_version"]) or "—"}</td>'
                "</tr>"
            )
        add("</tbody></table></div>")

    # --- footer ----------------------------------------------------------
    add("<footer>")
    add(
        "<p>Generated from each repo's pacman database — the same "
        "<code>.db</code> file pacman downloads — by "
        f'<a href="{html.escape(site["source"])}/blob/main/.github/scripts/build-repo-index.py">'
        "build-repo-index.py</a>. Nothing on this page is hand-maintained.</p>"
    )
    add(
        '<p>Machine-readable: <a href="data/packages.csv">packages.csv</a> · '
        '<a href="data/changes.csv">changes.csv</a> · '
        f'<a href="{html.escape(site["source"])}">source</a></p>'
    )
    add("</footer>")
    add("</main>")
    add(f"<script>{SCRIPT}</script>")
    add("</body>")
    add("</html>")
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------


def digest(packages: list[dict], changes: list[dict], signing: list) -> str:
    """Fingerprint the data, ignoring the check timestamp.

    Only this decides whether there is anything worth committing, so a run that
    finds nothing new does not produce a commit whose entire content is a
    changed clock.
    """
    payload = json.dumps(
        {
            "packages": [[row[key] for key in PACKAGE_FIELDS] for row in packages],
            "changes": len(changes),
            "signing": signing,
        },
        sort_keys=True,
    )
    return hashlib.sha256(payload.encode()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, help="repo-index.json")
    parser.add_argument("--db-dir", required=True, help="directory holding the .db files")
    parser.add_argument("--out-dir", required=True, help="Pages checkout to write into")
    parser.add_argument(
        "--github-output",
        default=os.environ.get("GITHUB_OUTPUT"),
        help="where to write the changed=/summary= step outputs",
    )
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as handle:
        config = json.load(handle)

    data_dir = os.path.join(args.out_dir, "data")
    packages_csv = os.path.join(data_dir, "packages.csv")
    changes_csv = os.path.join(data_dir, "changes.csv")
    state_json = os.path.join(data_dir, "state.json")

    known = read_csv(packages_csv, PACKAGE_FIELDS)
    changes = read_csv(changes_csv, CHANGE_FIELDS)
    state = {}
    if os.path.exists(state_json):
        with open(state_json, encoding="utf-8") as handle:
            state = json.load(handle)

    seeding = not known and not changes
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    observed: dict[str, dict[str, dict]] = {}
    available: set[str] = set()
    missing: list[str] = []
    fingerprint = ""
    for repo in config["repos"]:
        path = os.path.join(args.db_dir, os.path.basename(repo["db"]))
        # A repo counts as signed when its database signature is present and
        # names an issuer. That is the same file pacman checks, so the page
        # cannot advertise SigLevel = Required for a repo that would fail it.
        repo["signed"] = False
        if os.path.exists(path + ".sig"):
            issuer = signing_fingerprint(path + ".sig")
            if issuer:
                repo["signed"] = True
                fingerprint = fingerprint or issuer
        if not os.path.exists(path) or os.path.getsize(path) == 0:
            missing.append(repo["name"])
            print(f"::warning::no database for [{repo['name']}] at {path}; "
                  "keeping its last known contents")
            continue
        try:
            observed[repo["name"]] = db_to_rows(repo["name"], parse_db(path))
        except (tarfile.TarError, OSError) as exc:
            missing.append(repo["name"])
            print(f"::warning::could not read the database for [{repo['name']}]: {exc}")
            continue
        available.add(repo["name"])

    if not available:
        print("::error::no repo database could be read; refusing to rewrite the index")
        return 1

    packages, events = reconcile(known, observed, available, now, seeding)
    changes = (changes + events)[-MAX_CHANGES:]

    signing_state = [fingerprint] + [
        [r["name"], bool(r.get("signed"))] for r in config["repos"]
    ]
    new_digest = digest(packages, changes, signing_state)
    old_digest = state.get("data_digest", "")
    last_checked = state.get("last_checked_utc", "")
    stale = True
    if last_checked:
        try:
            age = (
                datetime.now(timezone.utc)
                - datetime.strptime(last_checked, "%Y-%m-%dT%H:%M:%SZ").replace(
                    tzinfo=timezone.utc
                )
            ).total_seconds()
            stale = age >= STALE_AFTER_SECONDS
        except ValueError:
            stale = True

    changed = new_digest != old_digest or stale or not os.path.exists(
        os.path.join(args.out_dir, "index.html")
    )

    if changed:
        write_csv(packages_csv, PACKAGE_FIELDS, packages)
        write_csv(changes_csv, CHANGE_FIELDS, changes)
        with open(state_json, "w", encoding="utf-8") as handle:
            json.dump(
                {"last_checked_utc": now, "data_digest": new_digest},
                handle,
                indent=2,
                sort_keys=True,
            )
            handle.write("\n")
        with open(os.path.join(args.out_dir, "index.html"), "w", encoding="utf-8") as handle:
            handle.write(render(config, packages, changes, now, fingerprint))
        # Static serving. Without this GitHub runs the site through Jekyll on
        # every push, which would be a build step standing between a published
        # package and its availability -- and this repo's real job is serving
        # several hundred megabytes of .pkg.tar.zst.
        open(os.path.join(args.out_dir, ".nojekyll"), "a").close()

    counts: dict[str, int] = {}
    for event in events:
        counts[event["event"]] = counts.get(event["event"], 0) + 1
    summary = ", ".join(f"{count} {name}" for name, count in sorted(counts.items()))
    if not summary:
        summary = "no package changes"
    if missing:
        summary += f" (no database for: {', '.join(sorted(missing))})"

    signed_names = [r["name"] for r in config["repos"] if r.get("signed")]
    print(
        f"{len(packages)} packages across {len(available)} repo(s); {summary}; "
        f"signed: {', '.join(signed_names) if signed_names else 'none'}"
        + (f" (key {fingerprint})" if fingerprint else "")
    )
    for event in events:
        print(
            f"  {event['event']:8} [{event['repo']}] {event['pkgname']} "
            f"{event['from_version'] or '-'} -> {event['to_version'] or '-'}"
        )
    print(f"changed={changed}")

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(f"changed={'true' if changed else 'false'}\n")
            handle.write(f"summary={summary}\n")
            handle.write(f"packages={len(packages)}\n")
            handle.write(f"fingerprint={fingerprint}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
