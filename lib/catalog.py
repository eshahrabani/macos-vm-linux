#!/usr/bin/env python3
"""Resolve the latest macOS full-installer (InstallAssistant.pkg) from Apple's
public sucatalog. Prints one JSON line: {"version", "title", "url", "size"}.

Only products whose packages include an InstallAssistant.pkg are considered
(these are the downloadable full installers). Version is read from the
product's Distribution plist (fallback: ExtendedMetaInfo.ProductVersion).
The version cap (MAX_MACOS) lives in common.sh.
"""
import gzip
import json
import plistlib
import sys
import urllib.request

CATALOGS = [
    "https://swscan.apple.com/content/catalogs/others/"
    "index-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    "https://swscan.apple.com/content/catalogs/others/"
    "index-11-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
]

MAX_MACOS = int(sys.argv[1]) if len(sys.argv) > 1 else 26


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def load_catalog(url):
    data = fetch(url)
    if url.endswith(".gz"):
        data = gzip.decompress(data)
    return plistlib.loads(data)


def parse_version(s):
    parts = []
    for p in s.split("."):
        try:
            parts.append(int(p))
        except ValueError:
            break
    return tuple(parts)


def product_version(catalog, pid):
    info = catalog["Products"][pid]
    emi = info.get("ExtendedMetaInfo", {})
    if isinstance(emi, dict) and "ProductVersion" in emi:
        return str(emi["ProductVersion"])
    dist = info.get("Distributions", {})
    url = dist.get("English") or next(iter(dist.values()))
    try:
        d = plistlib.loads(fetch(url))
        return d.get("VERSION", "")
    except Exception:
        return ""


def main():
    catalog = None
    for url in CATALOGS:
        try:
            catalog = load_catalog(url)
            break
        except Exception:
            continue
    if catalog is None:
        sys.stderr.write("catalog: could not fetch any Apple sucatalog\n")
        sys.exit(1)

    best = None
    for pid, info in catalog.get("Products", {}).items():
        pkgs = info.get("Packages", [])
        url = next((p.get("URL") for p in pkgs if "InstallAssistant.pkg" in p.get("URL", "")), None)
        if not url:
            continue
        v = parse_version(product_version(catalog, pid))
        if not v or v[0] > MAX_MACOS:
            continue
        size = next((p.get("Size", 0) for p in pkgs if p.get("URL") == url), 0)
        if best is None or v > best[0]:
            best = (v, info.get("title", pid), url, size)

    if best is None:
        sys.stderr.write("catalog: no InstallAssistant.pkg product found (cap %d)\n" % MAX_MACOS)
        sys.exit(1)

    print(json.dumps({
        "version": ".".join(str(x) for x in best[0]),
        "title": best[1],
        "url": best[2],
        "size": best[3],
    }))


if __name__ == "__main__":
    main()
