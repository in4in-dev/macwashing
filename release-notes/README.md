# Release notes

`<version>.en.md` and `<version>.ru.md` for every published app version (`MARKETING_VERSION`), written before
`Scripts/release/publish-release.sh`, which refuses to publish without both. Plain text: a line starting with `- `
becomes a list item, other non-empty lines paragraphs. Sparkle shows them in its update window in the user's language;
the GitHub release and [CHANGELOG.md](../CHANGELOG.md) are made from them (`Scripts/release/notes.py`).
`dates.txt` keeps the day each version came out.

Keep them short and about what the user notices: what got better, not how; no fixed bugs; internals as one line
(«Helper improvements»).
