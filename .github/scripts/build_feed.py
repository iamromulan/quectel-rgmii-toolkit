#!/usr/bin/env python3
"""Update an opkg feed directory in place with freshly built .ipk files.

Usage: build_feed.py <feed-dir> <ipk> [<ipk> ...]
                     [--summary DIFF_FILE] [--export DIR]

For every new ipk (identified by the Package: field of its control file, never
by its filename):

  * the matching stanza in <feed-dir>/Packages is replaced in place; a package
    that is not in the index yet is appended. Every other stanza is left
    byte-for-byte untouched, including the blank-line separators the feed
    already uses;
  * the ipk is copied into <feed-dir>;
  * superseded ipks (other *.ipk in <feed-dir> whose control Package: matches
    a rebuilt package) are deleted;
  * Packages.gz is rewritten deterministically (no mtime, no filename).

Packages.sig is NOT touched: signing happens in a separate step that holds the
key. A summary in Markdown goes to stdout; --summary writes a unified diff of
the old and new Packages; --export copies the files a signer needs (Packages,
Packages.gz, the new ipks, deleted.txt, packages.txt) into DIR.

New stanza layout (mirrors the feed's hand-written stanzas): the ipk's control
fields in control order (without Description and LicenseFiles), Section and
License carried over from the replaced stanza when the control file has none,
then MD5Sum, SHA256sum, Size, Filename, then the Description with its
continuation lines.

Python 3.8+ standard library only.
"""

import argparse
import difflib
import hashlib
import io
import os
import re
import shutil
import struct
import sys
import tarfile
import zlib

FILE_FIELDS = ("Filename", "Size", "MD5Sum", "SHA256sum")
DROP_FIELDS = ("LicenseFiles",)
CARRY_OVER = ("Section", "License")
DEFAULT_SEP = b"\n\n\n"
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*\.ipk$")


def fail(msg):
    print("build_feed: error: " + msg, file=sys.stderr)
    sys.exit(1)


def warn(msg):
    print("build_feed: warning: " + msg, file=sys.stderr)


# ---------------------------------------------------------------- ipk reading

def _ar_members(raw):
    members = {}
    pos = 8
    while pos + 60 <= len(raw):
        hdr = raw[pos:pos + 60]
        name = hdr[:16].decode("ascii", "replace").strip().rstrip("/")
        size = int(hdr[48:58].decode("ascii").strip())
        pos += 60
        members[name] = raw[pos:pos + size]
        pos += size + (size & 1)
    return members


def _tar_members(raw, mode):
    members = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode=mode) as tar:
        for info in tar:
            if info.isfile():
                name = info.name
                while name.startswith("./"):
                    name = name[2:]
                members[name] = tar.extractfile(info).read()
    return members


def read_control(path):
    """Return the control file text of an ipk (gzip'd tar or ar layout)."""
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw[:8] == b"!<arch>\n":
        outer = _ar_members(raw)
    else:
        outer = _tar_members(raw, "r:gz")
    ctrl_tgz = outer.get("control.tar.gz")
    if ctrl_tgz is None:
        raise ValueError("no control.tar.gz")
    inner = _tar_members(ctrl_tgz, "r:gz")
    if "control" not in inner:
        raise ValueError("no control file in control.tar.gz")
    return inner["control"].decode("utf-8", "surrogateescape").replace("\r\n", "\n")


# ------------------------------------------------------------- field parsing

def parse_fields(text):
    """Return [(key, [lines])] in order; continuation lines stay with their field."""
    fields = []
    for line in text.split("\n"):
        if not line.strip():
            continue
        if line[0] in " \t":
            if not fields:
                raise ValueError("continuation line before any field")
            fields[-1][1].append(line.rstrip())
        elif ":" in line:
            fields.append((line.partition(":")[0].strip(), [line.rstrip()]))
        else:
            raise ValueError("malformed control line: %r" % line)
    return fields


def field_value(fields, key):
    for k, lines in fields:
        if k == key:
            return lines[0].partition(":")[2].strip()
    return ""


# ------------------------------------------------------------ Packages index

def split_index(data):
    """Split the index into chunks [(package_name_or_None, bytes)]."""
    starts = [m.start() for m in re.finditer(rb"^Package:", data, re.M)]
    if not starts:
        return [(None, data)] if data else []
    chunks = []
    if starts[0] > 0:
        chunks.append((None, data[:starts[0]]))
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(data)
        chunk = data[start:end]
        first = chunk.split(b"\n", 1)[0]
        name = first[len(b"Package:"):].decode("utf-8", "replace").strip()
        chunks.append((name, chunk))
    return chunks


def _trailing(chunk):
    body = chunk.rstrip(b"\n")
    return body, chunk[len(body):]


def make_stanza(fields, filename, size, md5, sha256, old_fields):
    present = set(k for k, _ in fields)
    out = []
    desc = None
    for key, lines in fields:
        if key in FILE_FIELDS or key in DROP_FIELDS:
            continue
        if key == "Description":
            desc = lines
            continue
        out.extend(lines)
    if old_fields:
        for key in CARRY_OVER:
            if key not in present:
                for k, lines in old_fields:
                    if k == key:
                        out.extend(lines)
                        break
    out.append("MD5Sum: " + md5)
    out.append("SHA256sum: " + sha256)
    out.append("Size: " + str(size))
    out.append("Filename: " + filename)
    if desc:
        out.extend(desc)
    # No final newline: the separator run (which includes the line terminator)
    # is appended by the caller.
    return "\n".join(out).encode("utf-8", "surrogateescape")


def deterministic_gzip(data):
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    body = comp.compress(data) + comp.flush()
    header = b"\x1f\x8b\x08\x00" + struct.pack("<I", 0) + b"\x02\xff"
    trailer = struct.pack("<II", zlib.crc32(data) & 0xFFFFFFFF, len(data) & 0xFFFFFFFF)
    return header + body + trailer


def file_digests(path):
    md5 = hashlib.md5()
    sha = hashlib.sha256()
    size = 0
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            md5.update(block)
            sha.update(block)
            size += len(block)
    return size, md5.hexdigest(), sha.hexdigest()


# ---------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="Update an opkg feed with new ipks")
    ap.add_argument("feed_dir")
    ap.add_argument("ipks", nargs="+")
    ap.add_argument("--summary", help="write a unified diff of Packages here")
    ap.add_argument("--export", help="copy the signer's inputs into this dir")
    args = ap.parse_args()

    feed = args.feed_dir
    index_path = os.path.join(feed, "Packages")
    if not os.path.isdir(feed):
        fail("feed dir not found: " + feed)
    with open(index_path, "rb") as fh:
        old_data = fh.read()

    # 1. Read the new ipks.
    new = {}  # Package -> dict
    for path in args.ipks:
        fname = os.path.basename(path)
        if not SAFE_NAME.match(fname):
            fail("unsafe ipk filename: " + fname)
        try:
            fields = parse_fields(read_control(path))
        except Exception as exc:  # noqa: BLE001 - report any parse failure
            fail("%s: cannot read control: %s" % (fname, exc))
        pkg = field_value(fields, "Package")
        if not pkg:
            fail("%s: control has no Package field" % fname)
        if pkg in new:
            fail("two new ipks for package %s (%s, %s)" % (pkg, new[pkg]["file"], fname))
        size, md5, sha = file_digests(path)
        new[pkg] = {"path": path, "file": fname, "fields": fields, "version":
                    field_value(fields, "Version"), "size": size, "md5": md5, "sha": sha}

    # 2. Replace / append stanzas.
    chunks = split_index(old_data)
    replaced, added, dropped_dups = [], [], []
    done = set()
    result = []
    for name, chunk in chunks:
        if name is None or name not in new:
            result.append((name, chunk))
            continue
        info = new[name]
        _, trailing = _trailing(chunk)
        if name in done:
            dropped_dups.append(name)
            continue
        done.add(name)
        old_fields = parse_fields(chunk.decode("utf-8", "surrogateescape"))
        old_version = field_value(old_fields, "Version")
        stanza = make_stanza(info["fields"], info["file"], info["size"], info["md5"],
                             info["sha"], old_fields)
        if len(trailing) < 2:
            trailing = DEFAULT_SEP
        result.append((name, stanza + trailing))
        replaced.append((name, old_version, info["version"], info["file"]))

    missing = [p for p in new if p not in done]
    if missing:
        sep = DEFAULT_SEP
        if result:
            last_name, last_chunk = result[-1]
            body, trailing = _trailing(last_chunk)
            if len(trailing) >= 2:
                sep = trailing
            else:
                result[-1] = (last_name, body + sep)
        for pkg in missing:
            info = new[pkg]
            stanza = make_stanza(info["fields"], info["file"], info["size"],
                                 info["md5"], info["sha"], None)
            result.append((pkg, stanza + sep))
            added.append((pkg, info["version"], info["file"]))

    new_data = b"".join(chunk for _, chunk in result)

    # 3. Copy the ipks in and remove the superseded ones.
    new_files = set(i["file"] for i in new.values())
    for info in new.values():
        dst = os.path.join(feed, info["file"])
        if os.path.abspath(dst) != os.path.abspath(info["path"]):
            shutil.copyfile(info["path"], dst)
    removed = []
    for fname in sorted(os.listdir(feed)):
        if not fname.endswith(".ipk") or fname in new_files:
            continue
        try:
            pkg = field_value(parse_fields(read_control(os.path.join(feed, fname))), "Package")
        except Exception as exc:  # noqa: BLE001
            warn("cannot read %s, leaving it alone: %s" % (fname, exc))
            continue
        if pkg in new:
            os.remove(os.path.join(feed, fname))
            removed.append(fname)

    # 4. Write the index.
    changed = new_data != old_data
    if changed:
        with open(index_path, "wb") as fh:
            fh.write(new_data)
    gz_path = os.path.join(feed, "Packages.gz")
    gz_data = deterministic_gzip(new_data)
    gz_old = None
    if os.path.exists(gz_path):
        with open(gz_path, "rb") as fh:
            gz_old = fh.read()
    if gz_old != gz_data:
        with open(gz_path, "wb") as fh:
            fh.write(gz_data)

    # 5. Sanity: every Filename in the index should exist.
    for name, chunk in result:
        if name is None:
            continue
        fn = field_value(parse_fields(chunk.decode("utf-8", "surrogateescape")), "Filename")
        if fn and not os.path.exists(os.path.join(feed, fn)):
            warn("index entry %s points at missing file %s" % (name, fn))

    # 6. Reports.
    if args.summary:
        diff = difflib.unified_diff(
            old_data.decode("utf-8", "replace").splitlines(keepends=True),
            new_data.decode("utf-8", "replace").splitlines(keepends=True),
            "a/Packages", "b/Packages")
        with open(args.summary, "w", encoding="utf-8", newline="\n") as fh:
            fh.writelines(diff)

    if args.export:
        os.makedirs(args.export, exist_ok=True)
        shutil.copyfile(index_path, os.path.join(args.export, "Packages"))
        shutil.copyfile(gz_path, os.path.join(args.export, "Packages.gz"))
        for info in new.values():
            shutil.copyfile(os.path.join(feed, info["file"]),
                            os.path.join(args.export, info["file"]))
        with open(os.path.join(args.export, "deleted.txt"), "w", newline="\n") as fh:
            fh.write("".join(n + "\n" for n in removed))
        with open(os.path.join(args.export, "packages.txt"), "w", newline="\n") as fh:
            fh.write("".join(p + "\n" for p in sorted(new)))

    print("### opkg feed update")
    print("")
    for pkg, ov, nv, fn in replaced:
        print("- replaced `%s` %s -> %s (`%s`)" % (pkg, ov or "?", nv, fn))
    for pkg, nv, fn in added:
        print("- added `%s` %s (`%s`)" % (pkg, nv, fn))
    for fn in removed:
        print("- removed superseded `%s`" % fn)
    for pkg in dropped_dups:
        print("- dropped duplicate index stanza for `%s`" % pkg)
    if not changed:
        print("- Packages is unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main())
