#!/usr/bin/env python3
"""Project the newest appcast item into aginol.json.

The appcast is the authoritative feed; this file exists so a download page can
show the current version without parsing RSS. It is derived, never edited: the
only value not already in the feed is the SHA-256, which is computed from the
archive the feed points at.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from email.utils import parsedate_to_datetime
from pathlib import Path
from xml.etree import ElementTree

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def sparkle(name: str) -> str:
    return f"{{{SPARKLE_NS}}}{name}"


def item_build_number(item: ElementTree.Element) -> int:
    """Sparkle compares CFBundleVersion, which lives either in the item or the
    enclosure depending on the generator version."""
    for element in (item.find(sparkle("version")), item.find("enclosure")):
        if element is None:
            continue
        value = element.text if element.tag != "enclosure" else element.get(sparkle("version"))
        if value:
            try:
                return int(value.strip())
            except ValueError:
                # Non-numeric build numbers sort as "older than anything numeric"
                # rather than crashing the release.
                return -1
    return -1


def field(item: ElementTree.Element, tag: str) -> str | None:
    element = item.find(sparkle(tag))
    if element is not None and element.text:
        return element.text.strip()
    enclosure = item.find("enclosure")
    if enclosure is not None:
        value = enclosure.get(sparkle(tag))
        if value:
            return value.strip()
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", required=True, type=Path)
    parser.add_argument("--releases", required=True, type=Path)
    parser.add_argument("--appcast-url", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    tree = ElementTree.parse(args.appcast)
    items = tree.getroot().findall("./channel/item")
    if not items:
        print(f"{args.appcast} contains no items", file=sys.stderr)
        return 1

    newest = max(items, key=item_build_number)
    enclosure = newest.find("enclosure")
    if enclosure is None:
        print("Newest appcast item has no enclosure", file=sys.stderr)
        return 1

    url = enclosure.get("url") or ""
    archive = args.releases / Path(url).name
    if not archive.is_file():
        print(f"Archive {archive} referenced by the feed is missing", file=sys.stderr)
        return 1

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()

    pub_date = newest.findtext("pubDate")
    release_date = None
    if pub_date:
        try:
            release_date = parsedate_to_datetime(pub_date).date().isoformat()
        except (TypeError, ValueError):
            release_date = None

    manifest = {
        "version": field(newest, "shortVersionString") or "",
        "build": item_build_number(newest),
        "minimumSystemVersion": field(newest, "minimumSystemVersion"),
        "releaseDate": release_date,
        "downloadURL": url,
        "appcastURL": args.appcast_url,
        "fileSize": int(enclosure.get("length") or 0),
        "sha256": digest,
        "sparkleEdDSASignature": enclosure.get(sparkle("edSignature")),
        "releaseNotes": (newest.findtext("description") or "").strip() or None,
    }

    args.output.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"{args.output}: {manifest['version']} ({manifest['build']}) sha256={digest[:12]}…")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
