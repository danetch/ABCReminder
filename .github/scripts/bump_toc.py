#!/usr/bin/env python3
"""Add the live retail WoW interface version to the TOC's "## Interface:" line.

Reads Blizzard's public patch server (the same one the Battle.net launcher uses),
turns e.g. "12.1.5.66102" into 120105 and adds it to the TOC if it isn't listed yet.
Prints the new interface number when the file changed, nothing otherwise.
"""
import re
import sys
import urllib.request

VERSIONS_URL = "https://us.version.battle.net/v2/products/wow/versions"
TOC_PATH = "ABCReminder.toc"
KEEP = 6  # how many interface numbers to keep on the line


def live_version(text, region="us"):
    lines = [l for l in text.splitlines() if l.strip() and not l.startswith("##")]
    header = [h.split("!")[0] for h in lines[0].split("|")]
    region_col, version_col = header.index("Region"), header.index("VersionsName")
    for row in lines[1:]:
        cols = row.split("|")
        if cols[region_col] == region:
            return cols[version_col]
    raise ValueError(f"no row for region {region!r}")


def interface_number(version):
    major, minor, patch = (int(x) for x in version.split(".")[:3])
    return major * 10000 + minor * 100 + patch


def bump(toc_text, interface):
    m = re.search(r"^## Interface:\s*(.+)$", toc_text, re.MULTILINE)
    if not m:
        raise ValueError("no '## Interface:' line in the TOC")
    current = [int(x) for x in re.findall(r"\d+", m.group(1))]
    if interface in current:
        return None
    values = sorted(set(current + [interface]), reverse=True)[:KEEP]
    new_line = "## Interface: " + ", ".join(str(v) for v in values)
    return toc_text[:m.start()] + new_line + toc_text[m.end():]


def main():
    if len(sys.argv) > 1:  # local testing: pass a saved copy of the versions file
        text = open(sys.argv[1], encoding="utf-8").read()
    else:
        req = urllib.request.Request(VERSIONS_URL, headers={"User-Agent": "abcreminder-toc-bump"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            text = resp.read().decode("utf-8")

    interface = interface_number(live_version(text))
    with open(TOC_PATH, encoding="utf-8", newline="") as f:
        toc = f.read()
    new_toc = bump(toc, interface)
    if new_toc is None:
        return
    with open(TOC_PATH, "w", encoding="utf-8", newline="") as f:
        f.write(new_toc)
    print(interface)


if __name__ == "__main__":
    main()
