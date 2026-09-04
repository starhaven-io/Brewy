#!/usr/bin/env python3
"""Exercise release-note formatting and appcast rendering without publishing."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from string import Template
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
FORMATTER_PATH = ROOT / ".github" / "format-release-notes.py"
APPCAST_PATH = ROOT / ".github" / "appcast-template.xml"
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def load_formatter():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("format_release_notes", FORMATTER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Could not load the release-note formatter")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_release_notes() -> str:
    formatter = load_formatter()
    raw_notes = """## What's Changed
* feat(ui): render <trusted> & ]]> <evil> state by @contributor in https://github.com/starhaven-io/Brewy/pull/1
* fix: preserve an apostrophe's meaning by @contributor in https://github.com/starhaven-io/Brewy/pull/2
* ci: internal-only change by @contributor in https://github.com/starhaven-io/Brewy/pull/3
* uncategorized improvement by @contributor in https://github.com/starhaven-io/Brewy/pull/4
**Full Changelog**: https://github.com/starhaven-io/Brewy/compare/0.1.0...0.2.0
"""
    sections, changelog_url = formatter.parse_notes(raw_notes)
    assert sections == {
        "What's New": ["render <trusted> & ]]> <evil> state"],
        "Fixes": ["preserve an apostrophe's meaning"],
        "Other": ["uncategorized improvement"],
    }
    assert changelog_url == "https://github.com/starhaven-io/Brewy/compare/0.1.0...0.2.0"

    markdown = formatter.format_markdown("0.2.0", sections, changelog_url)
    assert "internal-only change" not in markdown
    assert "## Brewy 0.2.0" in markdown

    rendered_html = formatter.format_html("0.2.0", sections, changelog_url)
    assert "&lt;trusted&gt; &amp; ]]&gt; &lt;evil&gt; state" in rendered_html
    assert "<trusted>" not in rendered_html
    assert "]]>" not in rendered_html
    return rendered_html


def validate_appcast(release_notes_html: str) -> None:
    values = {
        "TAG": "0.2.0",
        "PUBDATE": "Wed, 02 Sep 2026 20:00:00 +0000",
        "BUILD_NUMBER": "42",
        "DOWNLOAD_URL": "https://github.com/starhaven-io/Brewy/releases/download/0.2.0/Brewy-0.2.0.zip",
        "SPARKLE_LENGTH": "123456",
        "SPARKLE_SIG": "base64-signature",
        "RELEASE_NOTES_HTML": release_notes_html,
    }
    rendered = Template(APPCAST_PATH.read_text(encoding="utf-8")).substitute(values)
    root = ET.fromstring(rendered)
    item = root.find("./channel/item")
    assert item is not None
    assert item.findtext("title") == values["TAG"]
    assert item.findtext(f"{{{SPARKLE_NAMESPACE}}}version") == values["BUILD_NUMBER"]
    assert item.find("evil") is None
    enclosure = item.find("enclosure")
    assert enclosure is not None
    assert enclosure.get("url") == values["DOWNLOAD_URL"]
    assert enclosure.get("length") == values["SPARKLE_LENGTH"]
    assert enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature") == values["SPARKLE_SIG"]


def main() -> None:
    release_notes_html = validate_release_notes()
    validate_appcast(release_notes_html)
    print("Release helper validation passed.")


if __name__ == "__main__":
    main()
