#!/usr/bin/env python3
"""Build an OpenWrt .ipk from a CONTROL/ + root/ package directory.

Usage: build_ipk.py <pkg-dir> [--out DIR] [--epoch SECONDS]

<pkg-dir> holds CONTROL/control (+ optional preinst/postinst/prerm/postrm/
conffiles) and root/ (the on-device file tree). Writes
<Package>_<Version>_<Architecture>.ipk into --out (default: current dir) and
prints its name, size, MD5 and SHA-256.

The format matches the iamromulan SDXPINN feed's existing packages: a gzip'd
tar holding debian-binary, control.tar.gz and data.tar.gz (not an ar archive),
inner members named ./path. Unlike the shell build-ipk it replaces, the
output does not depend on the checkout:
  * owner root:root and file modes are set per file, not read from disk, so a
    Windows checkout (no exec bits) builds the same package as Linux CI;
  * CRLF is stripped from CONTROL files, scripts (#!, *.sh, etc/init.d/) and
    *.nft/*.conf/*.env (core.autocrlf=true checkouts would otherwise ship
    "#!/bin/sh\\r"); web assets are left byte-for-byte;
  * entries are sorted, mtimes come from --epoch / SOURCE_DATE_EPOCH, and gzip
    headers carry no timestamp, so identical input gives identical bytes.

Executable (0755): CONTROL maintainer scripts, files starting with "#!",
ELF binaries, *.sh, and everything under bin/, sbin/, usr/bin/, usr/sbin/
and etc/init.d/. Everything else is 0644; directories are 0755.

Python 3.8+ standard library only. This file is kept byte-identical in
QManager (scripts-dev/ipk/) and the feed repo (.github/scripts/).
"""

import argparse
import gzip
import hashlib
import io
import os
import sys
import tarfile
import time

MAINTAINER_SCRIPTS = ("preinst", "postinst", "prerm", "postrm")
EXEC_DIRS = ("bin/", "sbin/", "usr/bin/", "usr/sbin/", "etc/init.d/")
TEXT_SUFFIXES = (".sh", ".nft", ".conf", ".env")
REQUIRED_FIELDS = ("Package", "Version", "Architecture")


def fail(msg):
    print("build_ipk: error: " + msg, file=sys.stderr)
    sys.exit(1)


def parse_control(data):
    fields = {}
    for line in data.decode("utf-8").splitlines():
        if not line or line[0] in " \t" or ":" not in line:
            continue
        key, _, value = line.partition(":")
        fields.setdefault(key.strip(), value.strip())
    for key in REQUIRED_FIELDS:
        if not fields.get(key):
            fail("CONTROL/control has no %s field" % key)
    return fields


def is_executable(rel, data, control):
    if control:
        return rel in MAINTAINER_SCRIPTS
    return (
        data.startswith(b"#!")
        or data.startswith(b"\x7fELF")
        or rel.endswith(".sh")
        or rel.startswith(EXEC_DIRS)
    )


def is_text(rel, data, control):
    if data.startswith(b"\x7fELF") or b"\0" in data[:8192]:
        return False
    return control or data.startswith(b"#!") or rel.endswith(TEXT_SUFFIXES) \
        or rel.startswith("etc/init.d/")


def collect(base, control):
    """Yield (rel, kind, payload, mode) sorted, kind in dir/file/link."""
    entries = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, base).replace(os.sep, "/")
        rel_dir = "" if rel_dir == "." else rel_dir + "/"
        if rel_dir:
            entries.append((rel_dir, "dir", None, 0o755))
        for name in dirnames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                entries.append((rel_dir + name, "link", os.readlink(path), 0o777))
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel = rel_dir + name
            if os.path.islink(path):
                entries.append((rel, "link", os.readlink(path), 0o777))
                continue
            with open(path, "rb") as fh:
                data = fh.read()
            if is_text(rel, data, control):
                data = data.replace(b"\r\n", b"\n")
            mode = 0o755 if is_executable(rel, data, control) else 0o644
            entries.append((rel, "file", data, mode))
    entries.sort(key=lambda e: e[0])
    return entries


def tar_gz(entries, epoch, prefix):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tar:
        if prefix:
            root = tarfile.TarInfo("./")
            root.type = tarfile.DIRTYPE
            root.mode = 0o755
            _own(root, epoch)
            tar.addfile(root)
        for rel, kind, payload, mode in entries:
            info = tarfile.TarInfo(prefix + rel)
            info.mode = mode
            _own(info, epoch)
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            elif kind == "link":
                info.type = tarfile.SYMTYPE
                info.linkname = payload
                tar.addfile(info)
            else:
                info.size = len(payload)
                tar.addfile(info, io.BytesIO(payload))
    out = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0, compresslevel=9) as gz:
        gz.write(raw.getvalue())
    return out.getvalue()


def _own(info, epoch):
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mtime = epoch


def main():
    ap = argparse.ArgumentParser(description="Build an OpenWrt .ipk")
    ap.add_argument("pkg_dir")
    ap.add_argument("--out", default=".")
    ap.add_argument("--epoch", type=int, default=None)
    args = ap.parse_args()

    control_dir = os.path.join(args.pkg_dir, "CONTROL")
    root_dir = os.path.join(args.pkg_dir, "root")
    if not os.path.isfile(os.path.join(control_dir, "control")):
        fail("%s/CONTROL/control not found" % args.pkg_dir)
    if not os.path.isdir(root_dir):
        fail("%s/root not found" % args.pkg_dir)

    epoch = args.epoch
    if epoch is None:
        epoch = int(os.environ.get("SOURCE_DATE_EPOCH") or time.time())

    control_entries = [e for e in collect(control_dir, True) if e[1] == "file"]
    control = dict((e[0], e[2]) for e in control_entries)
    fields = parse_control(control["control"])
    for name in control:
        if "/" in name:
            fail("CONTROL/ must be flat (found %s)" % name)

    data_entries = collect(root_dir, False)
    if not any(e[1] != "dir" for e in data_entries):
        fail("root/ is empty")

    control_tgz = tar_gz(control_entries, epoch, "./")
    data_tgz = tar_gz(data_entries, epoch, "./")
    outer = [
        ("debian-binary", "file", b"2.0\n", 0o644),
        ("control.tar.gz", "file", control_tgz, 0o644),
        ("data.tar.gz", "file", data_tgz, 0o644),
    ]
    ipk = tar_gz(outer, epoch, "")

    name = "%s_%s_%s.ipk" % (fields["Package"], fields["Version"], fields["Architecture"])
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, name)
    with open(path, "wb") as fh:
        fh.write(ipk)

    files = sum(1 for e in data_entries if e[1] != "dir")
    print(name)
    print("  files:  %d" % files)
    print("  size:   %d" % len(ipk))
    print("  md5:    %s" % hashlib.md5(ipk).hexdigest())
    print("  sha256: %s" % hashlib.sha256(ipk).hexdigest())


if __name__ == "__main__":
    main()
