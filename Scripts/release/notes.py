#!/usr/bin/env python3
"""Release notes → Sparkle's appcast and the changelog.

    notes.py appcast <repo> <owner/name>   writes updates/appcast.xml from updates/releases/*.json
    notes.py changelog <repo> <owner/name> writes CHANGELOG.md from release-notes/ and release-notes/dates.txt

Release notes are plain text (release-notes/<version>.en.md and .ru.md): a line starting with "- " is a list item,
any other non-empty line a paragraph. publish-release.sh runs both commands.
"""
import html
import json
import pathlib
import re
import sys


def version_key(version):
    return [int(part) if part.isdigit() else part for part in re.split(r"[.+-]", version)]


def paragraphs(text):
    """Blocks of the notes: ("p", line) or ("ul", [items])."""
    blocks = []
    for line in (line.strip() for line in text.splitlines()):
        if not line:
            continue
        if line.startswith("- "):
            if blocks and blocks[-1][0] == "ul":
                blocks[-1][1].append(line[2:])
            else:
                blocks.append(("ul", [line[2:]]))
        else:
            blocks.append(("p", line))
    return blocks


def notes_html(text):
    out = []
    for kind, value in paragraphs(text):
        if kind == "p":
            out.append(f"<p>{html.escape(value)}</p>")
        else:
            out.append("<ul>" + "".join(f"<li>{html.escape(item)}</li>" for item in value) + "</ul>")
    return "".join(out)


def notes_markdown(text):
    out = []
    for kind, value in paragraphs(text):
        out.append(value if kind == "p" else "\n".join(f"- {item}" for item in value))
    return "\n\n".join(out)


def appcast(repo, repository):
    releases = [json.loads(path.read_text()) for path in (repo / "updates" / "releases").glob("*.json")]
    releases.sort(key=lambda r: version_key(r["version"]), reverse=True)
    items = []
    for r in releases:
        url = f"https://github.com/{repository}/releases/download/v{r['version']}/{r['file']}"
        descriptions = "".join(
            f'\n      <description xml:lang="{lang}"><![CDATA[{notes_html(text).replace("]]>", "]]]]><![CDATA[>")}]]></description>'
            for lang, text in r["notes"].items()
        )
        items.append(f"""    <item>
      <title>{html.escape(r['version'])}</title>
      <pubDate>{html.escape(r['date'])}</pubDate>
      <sparkle:version>{r['build']}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(r['version'])}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(r['min_system'])}</sparkle:minimumSystemVersion>{descriptions}
      <enclosure url="{html.escape(url)}" length="{r['size']}" type="application/octet-stream"
                 sparkle:edSignature="{html.escape(r['ed_signature'])}"/>
    </item>""")
    text = f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Written by Scripts/release/publish-release.sh (notes.py appcast); do not edit by hand. -->
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MacWashing</title>
    <link>https://github.com/{repository}</link>
{chr(10).join(items)}
  </channel>
</rss>
"""
    (repo / "updates" / "appcast.xml").write_text(text)


def changelog(repo, repository):
    notes = repo / "release-notes"
    dates = {}
    for line in (notes / "dates.txt").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            version, date = line.split()
            dates[version] = date
    versions = sorted({p.name.split(".en.md")[0] for p in notes.glob("*.en.md")}, key=version_key, reverse=True)
    out = [
        "# Changelog",
        "",
        "What changed in each version of MacWashing. The rules database is also updated between app releases; the apps it",
        f"knows are listed on [the project page](https://{repository.split('/')[0]}.github.io/{repository.split('/')[1]}/apps/). Русская версия каждой записи — под английской.",
        "",
    ]
    for version in versions:
        date = dates.get(version, "")
        out.append(f"## {version}" + (f" — {date}" if date else ""))
        out.append("")
        out.append(notes_markdown((notes / f"{version}.en.md").read_text()))
        ru = notes / f"{version}.ru.md"
        if ru.exists():
            out.append("")
            out.append("<details><summary>По-русски</summary>")
            out.append("")
            out.append(notes_markdown(ru.read_text()))
            out.append("")
            out.append("</details>")
        out.append("")
    (repo / "CHANGELOG.md").write_text("\n".join(out))


if __name__ == "__main__":
    command, root = sys.argv[1], pathlib.Path(sys.argv[2])
    if command == "appcast":
        appcast(root, sys.argv[3])
    elif command == "changelog":
        changelog(root, sys.argv[3])
    else:
        sys.exit(f"unknown command {command}")
