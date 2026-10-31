#!/usr/bin/env python3
"""Plan an opkg feed build: which ipk-source packages to (re)build, bump or remove.

Usage:
  plan_build.py plan  --mode changed|all|listed [--packages "a b"] --out DIR
  plan_build.py adopt                                (record current trees, no build)

Common options: --src ipk-source  --feed opkg-feed  --state opkg-feed/build-state.json

State, not history. opkg-feed/build-state.json records, for every package
directory the feed was built from, a fingerprint of its CONTROL/ and root/ trees
(the files that go into the ipk) at that time. A package needs a rebuild exactly when its current tree hash differs from
the recorded one. Unlike a "what changed since commit X" search this survives
cancelled or queued runs, force-pushes, rebases and manual pushes, and running
twice is harmless.

Modes (plan):
  changed  packages whose tree differs from the state, plus packages whose
           directory was deleted (their stanza and ipk are removed)
  all      every package directory (deletions are handled too)
  listed   only the named directories (no deletions)

Version discipline: whoever changes a package's source is expected to bump its
Version. Only when the source changed and the Version still equals the feed's
is a package revision added as a fallback (1.2.3 -> 1.2.3-1, 1.2.3-1 -> 1.2.3-2,
an existing -rN stays -rN), written back into CONTROL/control in the working
tree so the source stays the source of truth. A human-edited Version is never
touched.
A source Version lower than the feed's is an error. Versions compare the way
opkg does (dpkg algorithm: epoch:upstream-revision, revision after the last '-').

The script runs git (rev-parse, add) in the current directory and edits only
CONTROL/control files; it never executes anything from a package directory.

Files written to --out: selected.txt (dirs to build), removed.txt (Package names
to drop), bumps.txt ("dir package old new"), state.json (the new state),
count (number of actions), src/<dir>/control (bumped control files for the signer).

Python 3.8+ standard library only.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

VALID_DIR = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
STATE_VERSION = 1


def fail(msg):
    print("plan_build: error: " + msg, file=sys.stderr)
    sys.exit(1)


def git(*args):
    res = subprocess.run(("git",) + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if res.returncode != 0:
        fail("git %s: %s" % (" ".join(args), res.stderr.decode("utf-8", "replace").strip()))
    return res.stdout.decode("utf-8", "replace").strip()


# ------------------------------------------------------------ version handling

def _order(ch):
    if ch is None or ch.isdigit():
        return 0
    if ch == "~":
        return -1
    if ch.isalpha():
        return ord(ch)
    return ord(ch) + 256


def _verrevcmp(a, b):
    """dpkg's verrevcmp: compare two version fragments."""
    i = j = 0
    while i < len(a) or j < len(b):
        while (i < len(a) and not a[i].isdigit()) or (j < len(b) and not b[j].isdigit()):
            ac = _order(a[i] if i < len(a) else None)
            bc = _order(b[j] if j < len(b) else None)
            if ac != bc:
                return ac - bc
            if i < len(a):
                i += 1
            if j < len(b):
                j += 1
        while i < len(a) and a[i] == "0":
            i += 1
        while j < len(b) and b[j] == "0":
            j += 1
        first_diff = 0
        while i < len(a) and a[i].isdigit() and j < len(b) and b[j].isdigit():
            if not first_diff:
                first_diff = ord(a[i]) - ord(b[j])
            i += 1
            j += 1
        if i < len(a) and a[i].isdigit():
            return 1
        if j < len(b) and b[j].isdigit():
            return -1
        if first_diff:
            return first_diff
    return 0


def _split_version(v):
    epoch = 0
    if ":" in v:
        e, _, v = v.partition(":")
        epoch = int(e) if e.isdigit() else 0
    upstream, _, revision = v.rpartition("-") if "-" in v else (v, "", "")
    return epoch, upstream, revision


def compare_versions(a, b):
    """Return <0, 0, >0 like opkg/dpkg would for versions a and b."""
    ea, ua, ra = _split_version(a)
    eb, ub, rb = _split_version(b)
    if ea != eb:
        return ea - eb
    r = _verrevcmp(ua, ub)
    return r if r else _verrevcmp(ra, rb)


def bump_version(v):
    """Packaging-only change, version not edited: OpenWrt style package revision.
    1.2.3 -> 1.2.3-1, 1.2.3-1 -> 1.2.3-2 (an existing -rN keeps its style)."""
    m = re.search(r"-(r?)(\d+)$", v)
    if m:
        return "%s-%s%d" % (v[:m.start()], m.group(1), int(m.group(2)) + 1)
    return v + "-1"


# ------------------------------------------------------------------- reading

def read_control(path):
    """Return {Package, Version, Architecture} of a CONTROL/control file."""
    fields = {}
    with open(path, "rb") as fh:
        for line in fh.read().decode("utf-8", "replace").splitlines():
            if line[:1] in (" ", "\t", "") or ":" not in line:
                continue
            key, _, val = line.partition(":")
            fields.setdefault(key.strip(), val.strip())
    for key in ("Package", "Version", "Architecture"):
        if not fields.get(key):
            fail("%s has no %s field" % (path, key))
    return fields


def feed_versions(feed_dir):
    """Package -> Version from the feed's Packages index."""
    path = os.path.join(feed_dir, "Packages")
    out = {}
    if not os.path.isfile(path):
        return out
    pkg = None
    with open(path, "rb") as fh:
        for line in fh.read().decode("utf-8", "replace").splitlines():
            if line.startswith("Package:"):
                pkg = line.partition(":")[2].strip()
            elif line.startswith("Version:") and pkg and pkg not in out:
                out[pkg] = line.partition(":")[2].strip()
    return out


def package_dirs(src):
    dirs = []
    for name in sorted(os.listdir(src)):
        if (VALID_DIR.match(name)
                and os.path.isfile(os.path.join(src, name, "CONTROL", "control"))):
            dirs.append(name)
    return dirs


def load_state(path):
    if not os.path.isfile(path):
        return {}
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if data.get("version") != STATE_VERSION or not isinstance(data.get("packages"), dict):
        fail("%s: unsupported state file" % path)
    return data["packages"]


def write_state(path, packages):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump({"version": STATE_VERSION, "packages": packages}, fh,
                  indent=2, sort_keys=True)
        fh.write("\n")


def tree_of(src, d):
    """Fingerprint of what ends up in the ipk: the git trees of CONTROL/ and root/
    as staged in the index (they equal HEAD's until a bump is staged), combined.
    Files beside them (notes, helper scripts) never trigger a rebuild. The
    index has no tree entries, so ask write-tree. The sign job recomputes this
    in shell: sha1 of "<CONTROL tree> <root tree>\n"."""
    parts = [git("write-tree", "--prefix=%s/%s/%s/" % (src, d, sub))
             for sub in ("CONTROL", "root")]
    return hashlib.sha1(("%s %s\n" % tuple(parts)).encode("ascii")).hexdigest()


def entry_for(src, d, ctl):
    return {
        "package": ctl["Package"],
        "version": ctl["Version"],
        "ipk": "%s_%s_%s.ipk" % (ctl["Package"], ctl["Version"], ctl["Architecture"]),
        "tree": tree_of(src, d),
    }


def rewrite_version(path, new_version):
    """Replace the Version line, leaving every other byte (and line ending) alone."""
    with open(path, "rb") as fh:
        data = fh.read()
    new, n = re.subn(rb"(?m)^Version:[^\r\n]*", b"Version: " + new_version.encode(), data, count=1)
    if n != 1:
        fail("%s: no Version line to rewrite" % path)
    with open(path, "wb") as fh:
        fh.write(new)


# ---------------------------------------------------------------------- plan

def cmd_plan(args):
    src, feed = args.src, args.feed
    state = load_state(args.state)
    dirs = package_dirs(src)
    fv = feed_versions(feed)

    seen = {}
    for d in dirs:
        pkg = read_control(os.path.join(src, d, "CONTROL", "control"))["Package"]
        if pkg in seen:
            fail("directories %s and %s both build package %s" % (seen[pkg], d, pkg))
        seen[pkg] = d

    removed = []  # (dir, package)
    if args.mode == "all":
        selected = list(dirs)
    elif args.mode == "listed":
        selected = []
        for d in args.packages.replace(",", " ").split():
            if not VALID_DIR.match(d):
                fail("invalid package name: " + d)
            if d not in dirs:
                fail("ipk-source/%s/CONTROL/control not found" % d)
            if d not in selected:
                selected.append(d)
        if not selected:
            fail("mode 'listed' needs at least one package in 'packages'")
    else:
        selected = [d for d in dirs if state.get(d, {}).get("tree") != tree_of(src, d)]
    if args.mode in ("changed", "all"):
        for d in sorted(state):
            if d not in dirs:
                removed.append((d, state[d].get("package", d)))

    os.makedirs(os.path.join(args.out, "src"), exist_ok=True)
    new_state = dict(state)
    bumps = []
    for d in selected:
        cpath = os.path.join(src, d, "CONTROL", "control")
        ctl = read_control(cpath)
        pkg, ver = ctl["Package"], ctl["Version"]
        changed = state.get(d, {}).get("tree") != tree_of(src, d)
        if pkg in fv:
            cmp_ = compare_versions(ver, fv[pkg])
            if cmp_ < 0:
                fail("%s: source Version %s is lower than the feed's %s" % (d, ver, fv[pkg]))
            if cmp_ == 0 and changed:
                new_ver = bump_version(ver)
                if compare_versions(new_ver, fv[pkg]) <= 0:
                    fail("%s: cannot bump %s above %s" % (d, ver, fv[pkg]))
                rewrite_version(cpath, new_ver)
                git("add", "--", cpath)
                bumps.append((d, pkg, ver, new_ver))
                ctl = read_control(cpath)
                os.makedirs(os.path.join(args.out, "src", d), exist_ok=True)
                with open(cpath, "rb") as fh, \
                        open(os.path.join(args.out, "src", d, "control"), "wb") as out:
                    out.write(fh.read())
        new_state[d] = entry_for(src, d, ctl)
    for d, _ in removed:
        new_state.pop(d, None)

    write_state_files(args, selected, removed, bumps, new_state)

    print("Mode: %s" % args.mode)
    print("Build (%d): %s" % (len(selected), " ".join(selected) or "-"))
    for d, pkg, old, new in bumps:
        print("  auto-bump %s: %s -> %s" % (d, old, new))
    print("Remove (%d): %s" % (len(removed), " ".join(p for _, p in removed) or "-"))
    return 0


def write_state_files(args, selected, removed, bumps, new_state):
    def lines(name, rows):
        with open(os.path.join(args.out, name), "w", newline="\n") as fh:
            fh.write("".join(r + "\n" for r in rows))
    lines("selected.txt", selected)
    lines("removed.txt", [p for _, p in removed])
    lines("bumps.txt", ["%s %s %s %s" % b for b in bumps])
    write_state(os.path.join(args.out, "state.json"), new_state)
    lines("count", [str(len(selected) + len(removed))])


def cmd_adopt(args):
    """Record the current trees as the built state, without building anything."""
    packages = {}
    for d in package_dirs(args.src):
        packages[d] = entry_for(args.src, d, read_control(
            os.path.join(args.src, d, "CONTROL", "control")))
    write_state(args.state, packages)
    print("Adopted %d packages into %s" % (len(packages), args.state))
    return 0


def main():
    ap = argparse.ArgumentParser(description="Plan an opkg feed build")
    ap.add_argument("command", choices=("plan", "adopt"))
    ap.add_argument("--src", default="ipk-source")
    ap.add_argument("--feed", default="opkg-feed")
    ap.add_argument("--state", default="opkg-feed/build-state.json")
    ap.add_argument("--mode", choices=("changed", "all", "listed"), default="changed")
    ap.add_argument("--packages", default="")
    ap.add_argument("--out", default="plan")
    args = ap.parse_args()
    return cmd_plan(args) if args.command == "plan" else cmd_adopt(args)


if __name__ == "__main__":
    sys.exit(main())
