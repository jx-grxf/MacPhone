#!/usr/bin/env python3
"""Merge the newest release item into the moving Sparkle beta feed."""

from __future__ import annotations

import sys
from pathlib import Path
from xml.dom import minidom


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def item_key(item: minidom.Element) -> tuple[str, str]:
    version = item.getElementsByTagName("sparkle:shortVersionString")
    build = item.getElementsByTagName("sparkle:version")
    return (
        version[0].firstChild.nodeValue.strip() if version and version[0].firstChild else "",
        build[0].firstChild.nodeValue.strip() if build and build[0].firstChild else "",
    )


def build_number(item: minidom.Element) -> int:
    try:
        return int(item_key(item)[1])
    except ValueError:
        return 0


def load(path: Path) -> minidom.Document:
    try:
        return minidom.parse(str(path))
    except Exception as error:
        fail(f"could not parse {path}: {error}")


if len(sys.argv) != 4:
    fail("usage: merge_beta_appcast.py CURRENT [PREVIOUS] OUTPUT")

current_path = Path(sys.argv[1])
previous_path = Path(sys.argv[2]) if sys.argv[2] else None
output_path = Path(sys.argv[3])

document = load(current_path)
channel_nodes = document.getElementsByTagName("channel")
if not channel_nodes:
    fail(f"{current_path} has no channel")
channel = channel_nodes[0]

items: list[minidom.Element] = [
    item for item in document.getElementsByTagName("item")
]
if previous_path and previous_path.is_file():
    previous = load(previous_path)
    items.extend(previous.getElementsByTagName("item"))

unique: dict[tuple[str, str], minidom.Element] = {}
for item in items:
    key = item_key(item)
    if key != ("", "") and key not in unique:
        unique[key] = item

for child in list(channel.childNodes):
    if child.nodeType == child.ELEMENT_NODE and child.nodeName == "item":
        channel.removeChild(child)

for item in sorted(unique.values(), key=build_number, reverse=True)[:20]:
    channel.appendChild(document.importNode(item, deep=True))

output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(document.toxml(encoding="utf-8").decode("utf-8") + "\n")
print(f"Wrote {output_path} with {len(unique)} release item(s)")
