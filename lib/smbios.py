#!/usr/bin/env python3
"""SMBIOS generation + injection for the OpenCore config.plist (stdlib only).

Port of acidanthera's macserial serial/MLB generation algorithm for the two
supported SMBIOS models (see docs/research.md), plus plist injection and
best-effort Apple-side checks.

usage:
  smbios.py generate [--model iMac19,1] [--count N]
      -> one "SERIAL|MLB" per line
  smbios.py inject <config.plist> [--model M] [--serial S] [--mlb M] [--uuid U] [--rom HEX]
      -> writes the plist (values generated when omitted), prints SERIAL|MLB|UUID|MODEL|ROM
  smbios.py show <config.plist>        -> prints current SERIAL|MLB|UUID|MODEL|ROM
  smbios.py check [--serial S] [--mlb M] [--model M]
      -> best-effort: checkcoverage.apple.com + osrecovery MLB acceptance
  smbios.py info --serial S [--model M] -> decode/validate a serial
  smbios.py verify-mlb MLB              -> MLB checksum check

The "check" subcommand talks to Apple servers (network, rate-limited) and is
advisory only — the local format checks (info/verify-mlb) are the gate.
"""
import argparse
import json
import os
import plistlib
import random
import sys
import urllib.request
import uuid as uuidlib

# --- macserial tables (acidanthera/macserial, BSD-3-Clause; ported verbatim) ---

BASE34 = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"  # I and O excluded
TBL_BASE34 = [10, 11, 12, 13, 14, 15, 16, 17, 0, 18, 19, 20, 21, 22, 0,
              23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33]  # A..Z
TBL_YEAR = [0, 0, 0, 0, 0, 1, 1, 2, 0, 2, 3, 3, 4, 4, 0, 5, 5, 6, 6, 7,
            0, 7, 8, 8, 9, 9]
YEAR_REVERSE = "CDFGHJKLMNPQRSTVWXYZ"  # index = (year-2010)*2 + half
TBL_WEEK = [0, 0, 10, 11, 0, 12, 13, 14, 0, 15, 16, 17, 18, 19, 0, 20, 21,
            22, 0, 23, 0, 24, 25, 26, 27, 0]
WEEK_REVERSE = "0123456789CDFGHJKLMNPQRTVWX123456789CDFGHJKLMNPQRTVWXY"  # index = week
TBL_WEEK_ADD = [0, 0, 0, 26, 0, 0, 26, 0, 0, 26, 0, 26, 0, 26, 0, 0, 26,
                0, 26, 0, 0, 26, 0, 26, 0, 26]

MLB_BLOCK1 = ["200", "600", "403", "404", "405", "303", "108", "207", "609",
              "501", "306", "102", "701", "301", "501", "101", "300", "130",
              "100", "270", "310", "902", "104", "401", "902", "500", "700", "802"]
MLB_BLOCK2 = ["GU", "4N", "J9", "QX", "OP", "CD", "GU"]
MLB_BLOCK3 = ["1H", "1M", "AD", "1F", "A8", "UE", "JA", "JC", "8C", "CB", "FB"]

MODELS = {
    "iMac19,1": {
        "board_id": "Mac-AA95B1DDAB278B95",
        "base_serial": "C02Y90H3JV3Q",
        "model_codes": ["JV3Q", "JV3P", "JV40", "JV41", "JV42", "JV43", "MC9K",
                        "MC9J", "MX7W", "JV3N", "JV3T", "JV3W", "JV3R", "JV3Y",
                        "JV3X", "MW2R", "MW2P", "MW2Q", "MW2V", "MW2W", "MW2T",
                        "MQQP", "NY2G", "P1WV", "MMTC", "0H1M", "0H1L", "0H1K", "0H1J"],
        "board_codes": ["LNV9", "KDP0", "KDN8"],
        "years": [2019, 2020],
    },
    "iMac20,1": {
        "board_id": "Mac-CFF7D910A743CAAF",
        "base_serial": "C02D38RCPN5T",
        "model_codes": ["PN5T", "PN5Y", "PN5X", "PN5W", "PN5V", "PN78", "PN7D",
                        "PN77", "PN7C"],
        "board_codes": ["PHC1", "PHCD"],
        "years": [2020, 2021, 2022],
    },
}

SERIAL_LINE_MIN, SERIAL_LINE_REPR_MAX, SERIAL_LINE_MAX = 0, 1155, 3399
SERIAL_WEEK_MIN, SERIAL_WEEK_MAX = 1, 53


def verify_mlb_checksum(mlb):
    if len(mlb) not in (13, 17):
        return False
    checksum = 0
    for i, ch in enumerate(mlb):
        j = BASE34.find(ch)
        if j < 0:
            return False
        checksum += (((i & 1) == (len(mlb) & 1)) * 2 + 1) * j
    return checksum % 34 == 0


def line_to_rmin(line):
    if line > SERIAL_LINE_REPR_MAX:
        return (line - SERIAL_LINE_REPR_MAX + 67) // 68
    return 0


def decode_year_char(c, model_years):
    v = TBL_YEAR[ord(c) - ord("A")] if "A" <= c <= "Z" else -1
    if v < 0:
        return -1
    if model_years and model_years[0] >= 2017 and v < 7:
        v += 2020
    elif v >= 0:
        v += 2010
    return v


def decode_week_char(c, year_char):
    if "1" <= c <= "9":
        w = int(c)
    else:
        w = TBL_WEEK[ord(c) - ord("A")] if "A" <= c <= "Z" else -1
    if w > 0 and decode_year_char(year_char, None) >= 0:
        w += TBL_WEEK_ADD[ord(year_char) - ord("A")]
    return w


def generate_serial(model_name):
    m = MODELS[model_name]
    rng = random.SystemRandom()
    year = rng.choice(m["years"])
    week = rng.randint(SERIAL_WEEK_MIN, SERIAL_WEEK_MAX - 1)
    base = 2020 if year >= 2020 else 2010
    year_char = YEAR_REVERSE[(year - base) * 2 + (1 if week >= 27 else 0)]
    week_char = WEEK_REVERSE[week]
    line = rng.randint(SERIAL_LINE_MIN, SERIAL_LINE_MAX)
    rmin = line_to_rmin(line)
    line_chars = (BASE34[rmin]
                  + BASE34[(line - rmin * 68) // 34]
                  + BASE34[(line - rmin * 68) % 34])
    return m["base_serial"][:3] + year_char + week_char + line_chars + m["model_codes"][0]


def generate_mlb(model_name, serial):
    m = MODELS[model_name]
    rng = random.SystemRandom()
    year_char = serial[3]
    week_char = serial[4]
    src = "CDFGHJKLMNPQRSTVWXYZ"
    dst = "00112233445566778899"
    year = dst[src.index(year_char)]
    week = 27 if year_char in "DGJLNQSVXZ" else 0
    srcweek = "123456789CDFGHJKLMNPQRSTVWXYZ"
    week += srcweek.index(week_char) + 1
    week -= 1
    if week <= 9:
        if week == 0:
            week = SERIAL_WEEK_MAX
            year = "9" if year == "0" else str(int(year) - 1)
    board = m["board_codes"][0]
    for _ in range(1000):
        mlb = "%s%s%02d%s%s%s%s" % (
            serial[:3], year, week,
            rng.choice(MLB_BLOCK1), rng.choice(MLB_BLOCK2), board, rng.choice(MLB_BLOCK3))
        if verify_mlb_checksum(mlb):
            return mlb
    raise RuntimeError("could not generate a checksum-valid MLB")


def validate_serial(serial, model_name):
    """Local format validation (macserial-style decode). Returns (ok, reason)."""
    m = MODELS[model_name]
    if len(serial) != 12:
        return False, "serial must be 12 chars"
    if any(ch not in BASE34 for ch in serial):
        return False, "serial contains invalid chars (I/O excluded)"
    if serial[-4:] not in m["model_codes"]:
        return False, "serial model code %r not valid for %s" % (serial[-4:], model_name)
    y = decode_year_char(serial[3], m["years"])
    if y not in m["years"]:
        return False, "serial year %s not in %s production years %s" % (serial[3], model_name, m["years"])
    w = decode_week_char(serial[4], serial[3])
    if not (SERIAL_WEEK_MIN <= w <= SERIAL_WEEK_MAX):
        return False, "serial week decode out of range"
    return True, "ok"


def serial_info(serial, model_name=None):
    for name in MODELS:
        if model_name and name != model_name:
            continue
        ok, reason = validate_serial(serial, name)
        if ok:
            return {"model": name, "valid": True, "note": reason}
    if model_name:
        ok, reason = validate_serial(serial, model_name)
        return {"model": model_name, "valid": ok, "note": reason}
    return {"model": "unknown", "valid": False,
            "note": "does not decode for any supported model"}


def generate_pair(model_name):
    serial = generate_serial(model_name)
    return serial, generate_mlb(model_name, serial)


def _read_plist(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def _write_plist(path, plist):
    with open(path, "wb") as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_XML)


def _generic(plist):
    try:
        return plist["PlatformInfo"]["Generic"]
    except (KeyError, TypeError):
        raise SystemExit("config.plist: PlatformInfo/Generic not found — "
                         "OpenCore config format drift?")


def cmd_generate(args):
    for _ in range(args.count):
        s, m = generate_pair(args.model)
        print("%s|%s" % (s, m))


def cmd_inject(args):
    plist = _read_plist(args.plist)
    g = _generic(plist)
    model = args.model or g.get("SystemProductName", "iMac19,1")
    if model not in MODELS:
        raise SystemExit("unsupported model %r (iMac19,1|iMac20,1)" % model)

    serial = args.serial
    mlb = args.mlb
    uuidv = args.uuid
    if not (serial and mlb):
        fresh_s, fresh_m = generate_pair(model)
        serial = serial or fresh_s
        mlb = mlb or fresh_m
    ok, note = validate_serial(serial, model)
    if not ok:
        raise SystemExit("invalid serial: %s" % note)
    if not verify_mlb_checksum(mlb):
        raise SystemExit("invalid MLB checksum")
    uuidv = uuidv or str(uuidlib.uuid4()).upper()
    if len(serial) != 12 or len(mlb) != 17:
        raise SystemExit("unexpected serial/MLB length")

    g["SystemSerialNumber"] = serial
    g["MLB"] = mlb
    g["SystemUUID"] = uuidv
    g["SystemProductName"] = model
    if args.rom:
        try:
            rom = bytes.fromhex(args.rom)
        except ValueError:
            raise SystemExit("ROM must be 12 hex chars")
        if len(rom) != 6:
            raise SystemExit("ROM must be 12 hex chars")
        g["ROM"] = rom
    _write_plist(args.plist, plist)
    rom_hex = g.get("ROM", b"").hex() if isinstance(g.get("ROM"), (bytes, bytearray)) else ""
    print("%s|%s|%s|%s|%s" % (serial, mlb, uuidv, model, rom_hex))


def cmd_show(args):
    plist = _read_plist(args.plist)
    g = _generic(plist)
    rom = g.get("ROM")
    rom_hex = rom.hex() if isinstance(rom, (bytes, bytearray)) else ""
    print("%s|%s|%s|%s|%s" % (
        g.get("SystemSerialNumber", ""), g.get("MLB", ""),
        g.get("SystemUUID", ""), g.get("SystemProductName", ""), rom_hex))


VMHIDE_ENTRY = {
    "Arch": "Any",
    "BundlePath": "VMHide.kext",
    "Comment": "VMHide.kext",
    "Enabled": True,
    "ExecutablePath": "Contents/MacOS/VMHide",
    "MaxKernel": "",
    "MinKernel": "15.0.0",
    "PlistPath": "Contents/Info.plist",
}


def cmd_kextadd(args):
    """Ensure the VMHide kext entry exists in Kernel/Add (idempotent).

    VMHide (Carnations-Botanica/VMHide, Lilu plugin) hides kern.hv_vmm_present
    from Apple ID processes — macOS 15+ blocks sign-in when the kernel reports
    a hypervisor, regardless of SMBIOS validity. Requires Lilu >= 1.7.0."""
    plist = _read_plist(args.plist)
    try:
        add = plist["Kernel"]["Add"]
    except (KeyError, TypeError):
        raise SystemExit("config.plist: Kernel/Add not found — OpenCore config format drift?")
    for entry in add:
        if isinstance(entry, dict) and entry.get("BundlePath") == "VMHide.kext":
            entry.update(VMHIDE_ENTRY)
            _write_plist(args.plist, plist)
            return
    add.append(dict(VMHIDE_ENTRY))
    _write_plist(args.plist, plist)


def coverage_check(serial):
    """checkcoverage.apple.com: registered (real machine) vs unregistered.
    Since 2025 the page is a JS SPA — the API needs a browser session flow, so
    this usually reports unreachable. Kept as a best-effort probe."""
    url = "https://checkcoverage.apple.com/coverage?locale=en_US"
    req = urllib.request.Request(
        url, data=json.dumps({"serial": serial}).encode(),
        headers={"Content-Type": "application/json",
                 "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                               "AppleWebKit/537.36 (KHTML, like Gecko) "
                               "Chrome/120.0 Safari/537.36"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read().decode("utf-8", "replace")
    except Exception as e:
        return "unreachable", str(e)
    low = body.lower()
    if any(m in low for m in ("not valid", "not found", "invalid serial")):
        return "unregistered", "no real machine behind this serial (good)"
    if any(m in low for m in ("purchase date", "warranty", "covered",
                              "applecare", "estimated expiration")):
        return "registered", "serial belongs to a real machine — do not use it"
    return "unknown", "ambiguous response (endpoint may have changed)"


def osrecovery_mlb_check(mlb, model_name):
    """osrecovery.apple.com responds to the sn= field with the board-id. Not a
    strict validity gate (placeholders are accepted too) — advisory only:
    confirms the identity tuple reaches Apple's servers."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import recovery
    board_id = MODELS[model_name]["board_id"]
    try:
        meta = recovery.fetch_metadata(board_id, "latest", sn=mlb)
    except Exception as e:
        return "unreachable", str(e)
    if meta and meta.get("url"):
        return "accepted", "Apple's recovery server answered for this board-id+sn"
    return "rejected", "recovery server did not answer for this board-id+sn"


def cmd_check(args):
    results = []
    if args.serial:
        res, note = coverage_check(args.serial)
        results.append(("checkcoverage", res, note))
    if args.mlb and args.model:
        res, note = osrecovery_mlb_check(args.mlb, args.model)
        results.append(("osrecovery MLB", res, note))
    if not results:
        raise SystemExit("check needs --serial and/or --mlb --model")
    for name, res, note in results:
        print("%-16s %-12s %s" % (name, res, note))
    bad = any(res in ("registered", "rejected") for _, res, _ in results)
    sys.exit(1 if bad else 0)


def cmd_info(args):
    info = serial_info(args.serial, args.model)
    print("model: %s" % info["model"])
    print("valid: %s (%s)" % ("yes" if info["valid"] else "no", info["note"]))
    sys.exit(0 if info["valid"] else 1)


def cmd_verify_mlb(args):
    ok = verify_mlb_checksum(args.mlb)
    print("MLB checksum: %s" % ("valid" if ok else "invalid"))
    sys.exit(0 if ok else 1)


def main():
    p = argparse.ArgumentParser(prog="smbios.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("generate")
    g.add_argument("--model", default="iMac19,1", choices=sorted(MODELS))
    g.add_argument("--count", type=int, default=1)
    g.set_defaults(fn=cmd_generate)

    i = sub.add_parser("inject")
    i.add_argument("plist")
    i.add_argument("--model", default=None)
    i.add_argument("--serial", default=None)
    i.add_argument("--mlb", default=None)
    i.add_argument("--uuid", default=None)
    i.add_argument("--rom", default=None)
    i.set_defaults(fn=cmd_inject)

    s = sub.add_parser("show")
    s.add_argument("plist")
    s.set_defaults(fn=cmd_show)

    k = sub.add_parser("kextadd")
    k.add_argument("plist")
    k.set_defaults(fn=cmd_kextadd)

    c = sub.add_parser("check")
    c.add_argument("--serial", default=None)
    c.add_argument("--mlb", default=None)
    c.add_argument("--model", default=None, choices=sorted(MODELS))
    c.set_defaults(fn=cmd_check)

    n = sub.add_parser("info")
    n.add_argument("--serial", required=True)
    n.add_argument("--model", default=None, choices=sorted(MODELS))
    n.set_defaults(fn=cmd_info)

    v = sub.add_parser("verify-mlb")
    v.add_argument("mlb")
    v.set_defaults(fn=cmd_verify_mlb)

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
