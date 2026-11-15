#!/usr/bin/env python3
"""Checks one release tag's item in a Sparkle appcast.

  preflight <appcast> <tag> <build>   Before the build: the build number is new to the feed (a rerun of
                                      the same tag may reuse its own) and newer than every item on the
                                      tag's channel.
  verify <appcast> <tag> [--build N] [--before <appcast>]
                                      After generate_appcast, or against the live feed: exactly one item
                                      has this tag's DMG; its title and shortVersionString are the
                                      version; a stable tag has no sparkle:channel and a beta tag has
                                      channel beta; it is the newest item on that channel. --build also
                                      checks its sparkle:version. --before checks that the feed grew by
                                      exactly one item (or kept its size on a rerun of the same tag).

<appcast> may be - for stdin. Exits 1 and prints every failure when a check fails.
"""

import argparse
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def build_key(build):
    # Sparkle's SUStandardVersionComparator pads missing numeric parts with 0: 888 == 888.0 < 888.1 < 889.
    parts = [int(part) for part in build.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def read_items(path):
    root = ET.parse(sys.stdin if path == "-" else path).getroot()
    items = []
    for item in root.iter("item"):
        enclosure = item.find("enclosure")
        build = item.findtext(SPARKLE + "version")
        if build is None and enclosure is not None:
            build = enclosure.get(SPARKLE + "version")
        channel = item.find(SPARKLE + "channel")
        items.append({
            "title": item.findtext("title"),
            "build": build,
            "short": item.findtext(SPARKLE + "shortVersionString"),
            "channel": None if channel is None else channel.text,
            "url": "" if enclosure is None else enclosure.get("url", ""),
        })
    return items


def release(tag):
    version = tag[1:] if tag.startswith("v") else tag
    channel = "beta" if "-" in version else None
    return version, channel, f"/{tag}/OpenUsage-{version}.dmg"


def newer_failures(build, others, channel_name):
    return [
        f"build {build} is not newer than {other['title']} (build {other['build']}) on the {channel_name} channel"
        for other in others
        if build_key(other["build"]) >= build_key(build)
    ]


def preflight(args):
    _, channel, dmg = release(args.tag)
    channel_name = channel or "stable"
    items = read_items(args.appcast)
    failures = [
        f"build {args.build} already shipped as {item['title']} ({item['url']}); a new item would be merged into it"
        for item in items
        if build_key(item["build"]) == build_key(args.build) and not item["url"].endswith(dmg)
    ]
    others = [item for item in items if item["channel"] == channel and not item["url"].endswith(dmg)]
    failures += newer_failures(args.build, others, channel_name)
    return failures, f"build {args.build} is new and the newest on the {channel_name} channel"


def verify(args):
    version, channel, dmg = release(args.tag)
    channel_name = channel or "stable"
    items = read_items(args.appcast)
    mine = [item for item in items if item["url"].endswith(dmg)]
    if len(mine) != 1:
        return [f"expected exactly one item with enclosure *{dmg}, found {len(mine)}"], ""
    item = mine[0]
    failures = []
    if item["short"] != version:
        failures.append(f"shortVersionString is {item['short']!r}, expected {version!r}")
    if item["title"] != version:
        failures.append(f"title is {item['title']!r}, expected {version!r}")
    if item["channel"] != channel:
        expected = "no sparkle:channel element" if channel is None else f"channel {channel!r}"
        failures.append(f"sparkle:channel is {item['channel']!r}, expected {expected}")
    if args.build is not None and build_key(item["build"]) != build_key(args.build):
        failures.append(f"sparkle:version is {item['build']!r}, expected {args.build!r}")
    others = [other for other in items if other["channel"] == channel and other is not item]
    failures += newer_failures(item["build"], others, channel_name)
    if args.before is not None:
        before = read_items(args.before)
        rerun = any(other["url"].endswith(dmg) for other in before)
        expected = len(before) + (0 if rerun else 1)
        if len(items) != expected:
            failures.append(
                f"item count went {len(before)} -> {len(items)}, expected {expected}"
                + ("" if rerun else "; the new DMG was merged into an existing item or an item was dropped")
            )
    return failures, f"{args.tag}: build {item['build']}, newest on the {channel_name} channel, {len(items)} items"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    pre = commands.add_parser("preflight")
    pre.add_argument("appcast")
    pre.add_argument("tag")
    pre.add_argument("build")
    pre.set_defaults(run=preflight)
    ver = commands.add_parser("verify")
    ver.add_argument("appcast")
    ver.add_argument("tag")
    ver.add_argument("--build")
    ver.add_argument("--before")
    ver.set_defaults(run=verify)
    args = parser.parse_args()

    failures, summary = args.run(args)
    for failure in failures:
        print(f"Appcast check failed for {args.tag}: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"Appcast OK: {summary}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
