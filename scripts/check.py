#!/usr/bin/env python3
"""Repository structure checks. Standard library only; this is not a stack choice."""

import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
FENCE = re.compile(r"^```.*?^```", re.S | re.M)
INV_REF = re.compile(r"\bINV-(\d+)\b")

errors = []


def fail(msg):
    errors.append(msg)


def markdown_files():
    return sorted(p for p in ROOT.rglob("*.md") if ".git" not in p.parts)


def prose(path):
    return FENCE.sub("", path.read_text())


def slug(heading):
    s = re.sub(r"[^\w\- ]", "", heading.strip().lower())
    return s.replace(" ", "-")


def anchors(path):
    return {slug(m) for m in re.findall(r"^#+\s+(.*)$", prose(path), re.M)}


def check_links():
    for md in markdown_files():
        for target in LINK.findall(prose(md)):
            if re.match(r"^[a-z]+:", target):
                continue
            file_part, _, anchor = target.partition("#")
            dest = (md.parent / file_part).resolve() if file_part else md
            rel = md.relative_to(ROOT)
            if not dest.exists():
                fail(f"{rel}: broken link {target}")
            elif anchor and dest.suffix == ".md" and anchor not in anchors(dest):
                fail(f"{rel}: missing anchor {target}")


ENTRY_POINTS = {"README.md", "AGENTS.md", "CLAUDE.md"}


def link_targets(md):
    for target in LINK.findall(prose(md)):
        file_part = target.partition("#")[0]
        if file_part and not re.match(r"^[a-z]+:", target):
            yield (md.parent / file_part).resolve()


def check_orphans():
    linked = set()
    for md in markdown_files():
        linked.update(t for t in link_targets(md) if t != md.resolve())
    for md in markdown_files():
        rel = md.relative_to(ROOT)
        if str(rel) not in ENTRY_POINTS and md.resolve() not in linked:
            fail(f"{rel}: nothing links to it; link it from where a reader would look, or delete it")


def check_spec_version():
    version = (ROOT / "spec/VERSION").read_text().strip()
    m = re.search(r"^Version:\s*(\S+)", (ROOT / "spec/protocol.md").read_text(), re.M)
    if not m:
        fail("spec/protocol.md: no 'Version:' line")
    elif m.group(1) != version:
        fail(f"spec version mismatch: VERSION={version} spec={m.group(1)}")


def check_decisions():
    ddir = ROOT / "docs/decisions"
    files = {p.name for p in ddir.glob("[0-9][0-9][0-9][0-9]-*.md")}
    indexed = set(re.findall(r"\((\d{4}-[^)]+\.md)\)", (ddir / "README.md").read_text()))
    for name in sorted(files - indexed):
        fail(f"docs/decisions/{name}: not listed in docs/decisions/README.md")
    for name in sorted(files):
        if not re.search(r"^Status:", (ddir / name).read_text(), re.M):
            fail(f"docs/decisions/{name}: no 'Status:' line")


def check_invariants_cite_decisions():
    text = (ROOT / "docs/invariants.md").read_text()
    for block in re.split(r"(?m)^(?=\*\*INV-)", text)[1:]:
        if not re.search(r"decisions/\d{4}-", block):
            name = re.match(r"\*\*(INV-\d+)", block).group(1)
            fail(f"docs/invariants.md: {name} cites no decision record")


def check_invariant_refs():
    defined = set(re.findall(r"^\*\*INV-(\d+)\b", (ROOT / "docs/invariants.md").read_text(), re.M))
    for md in markdown_files():
        for n in INV_REF.findall(md.read_text()):
            if n not in defined:
                fail(f"{md.relative_to(ROOT)}: cites undefined INV-{n}")


def check_agent_files():
    if not (ROOT / "CLAUDE.md").read_text().startswith("@AGENTS.md"):
        fail("CLAUDE.md: must import @AGENTS.md so the constitution has one source")


BANNED = re.compile("atel" + "ier", re.I)  # assembled so this file passes its own check


def check_banned_words():
    for path in sorted(p for p in ROOT.rglob("*") if p.is_file() and ".git" not in p.parts):
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        if BANNED.search(text) or BANNED.search(str(path.relative_to(ROOT))):
            fail(f"{path.relative_to(ROOT)}: names the predecessor project; call it the predecessor")


def reuse_glob(pattern):
    """REUSE globbing: `*` stays within a directory, `**` crosses directories."""
    parts = (re.escape(p).replace(r"\*", "[^/]*") for p in pattern.split("**"))
    return re.compile(".*".join(parts) + "$")


def check_licenses():
    """Every file must have a licence declared in REUSE.toml (ADR 0017)."""
    config = tomllib.loads((ROOT / "REUSE.toml").read_text())
    rules = []
    for a in config.get("annotations", []):
        paths = a["path"] if isinstance(a["path"], list) else [a["path"]]
        rules += [(reuse_glob(p), a["SPDX-License-Identifier"]) for p in paths]
    texts = {p.stem for p in (ROOT / "LICENSES").glob("*.txt")}
    for lic in sorted({lic for _, lic in rules} - texts):
        fail(f"REUSE.toml: no licence text LICENSES/{lic}.txt")
    listed = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"],
                            cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    if not listed:
        fail("git ls-files returned nothing; cannot check licences")
    for f in listed:
        if f == "REUSE.toml" or f.startswith("LICENSES/") or not (ROOT / f).exists():
            continue
        if not any(rx.match(f) for rx, _ in rules):
            fail(f"{f}: no licence in REUSE.toml; code is AGPL-3.0-or-later, everything else CC0-1.0")


CLAIM = re.compile(r"\b(will be|not yet|currently|for now|at the moment|so far|soon)\b", re.I)


def report_claims():
    """Claims about the present go stale silently; list them for a person to recheck."""
    for md in markdown_files():
        if md.name == "open-questions.md":
            continue
        for n, line in enumerate(md.read_text().splitlines(), 1):
            if CLAIM.search(line):
                print(f"{md.relative_to(ROOT)}:{n}: {line.strip()}")


if sys.argv[1:] == ["--claims"]:
    report_claims()
    sys.exit(0)

for check in (check_banned_words, check_links, check_orphans, check_spec_version, check_decisions, check_invariants_cite_decisions, check_invariant_refs, check_agent_files, check_licenses):
    check()

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("ok")
