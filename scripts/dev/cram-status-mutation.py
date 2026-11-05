#!/usr/bin/env python3
"""Mutation check for the exit statuses that cram transcripts pin.

A cram transcript records only a command line's final status, so a command that
runs `jacquard` or `jac` must pin the tool's status itself, typically

    jacquard run x.jac > pipe.out 2>&1 || echo "exit=$?"; head -1 < pipe.out

(test/test_cram_status.ml rejects the masked forms). This check proves the pins
work: it runs each cram's commands twice in a scratch copy of the cram's
directory, once with the real tools and once with `jacquard`/`jac` wrappers that
shift every exit status by 50 (0 -> 50, n -> n + 50). Every pinned command block
(one that writes `pipe.out` or saves `status=$?`) must print something different
under the shift; a block whose output is unchanged would let a failing tool pass
its transcript.

The check runs the crams themselves, so it is a manual tool, not part of
`dune runtest`. Build first (`dune build bin/main.exe bin/jac`), then:

    scripts/dev/cram-status-mutation.py                 # every pinned block
    scripts/dev/cram-status-mutation.py --base main     # blocks changed since main
    scripts/dev/cram-status-mutation.py test/cli/fuel.t # one cram

Options: --bindir DIR holds main.exe and jac (default _build/default/bin);
--scratch DIR is a disposable work directory (default
.scratch/tmp/cram-status-mutation). Exit status 0 when every pinned block is
caught, 1 otherwise, 2 on a usage error.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHIFT = 50


def changed_lines(base):
    """Map cram path (repo-relative) -> set of 1-based line numbers changed since BASE."""
    out = subprocess.run(
        ["git", "-C", REPO, "diff", "-U0", base, "--", "test"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    res, path = {}, None
    for line in out.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
        if m and path and path.endswith(".t"):
            start, count = int(m.group(1)), int(m.group(2) or 1)
            res.setdefault(path, set()).update(range(start, start + count))
    return res


def blocks(path):
    """Yield (first line number, command text, line span) for each `  $ ` command."""
    lines = open(path, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        if lines[i].startswith("  $ "):
            start, cmd = i + 1, [lines[i][4:]]
            i += 1
            while i < len(lines) and lines[i].startswith("  > "):
                cmd.append(lines[i][4:])
                i += 1
            yield start, "\n".join(cmd), set(range(start, start + len(cmd)))
        else:
            i += 1


def pinned(cmd):
    return "pipe.out" in cmd or "status=$?" in cmd


def wrappers(directory, bindir, shift):
    os.makedirs(directory, exist_ok=True)
    for tool, target in (("jacquard", "main.exe"), ("jac", "jac")):
        path = os.path.join(directory, tool)
        real = os.path.join(bindir, target)
        with open(path, "w", encoding="utf-8") as fh:
            if shift:
                fh.write(f'#!/bin/sh\n"{real}" "$@"\ns=$?\nexit $((s + {shift}))\n')
            else:
                fh.write(f'#!/bin/sh\nexec "{real}" "$@"\n')
        os.chmod(path, 0o755)
    return directory


def run_cram(rel, script, wrapdir, root, tmp):
    """Run SCRIPT in a scratch tree mirroring the build layout; return {block line: output}."""
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(os.path.join(root, "test"))
    for entry in os.listdir(REPO):
        if entry not in ("test", "_build", ".git", ".scratch", "_opam"):
            os.symlink(os.path.join(REPO, entry), os.path.join(root, entry))
    cram_dir = os.path.dirname(rel)
    for entry in os.listdir(os.path.join(REPO, "test")):
        src = os.path.join(REPO, "test", entry)
        if os.path.join("test", entry) != cram_dir:
            os.symlink(src, os.path.join(root, "test", entry))
    cwd = os.path.join(root, cram_dir)
    shutil.copytree(os.path.join(REPO, cram_dir), cwd, ignore=shutil.ignore_patterns("*.t"))
    os.makedirs(tmp, exist_ok=True)
    env = dict(os.environ, PATH=wrapdir + os.pathsep + os.environ["PATH"], NO_COLOR="1", TMPDIR=tmp)
    proc = subprocess.run(
        ["sh", "-c", script],
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=3600,
    )
    outputs, cur = {}, None
    for line in proc.stdout.splitlines():
        m = re.match(r"@@BLOCK (\d+)$", line)
        if m:
            cur = int(m.group(1))
            outputs[cur] = []
        elif cur is not None:
            outputs[cur].append(line)
    shutil.rmtree(root, ignore_errors=True)
    return {k: "\n".join(v) for k, v in outputs.items()}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", help="only blocks with lines changed since this revision")
    ap.add_argument("--bindir", default=os.path.join(REPO, "_build", "default", "bin"))
    ap.add_argument("--scratch", default=os.path.join(REPO, ".scratch", "tmp", "cram-status-mutation"))
    ap.add_argument("crams", nargs="*", help="cram files (default: every test/**/*.t)")
    args = ap.parse_args()
    bindir = os.path.abspath(args.bindir)
    for target in ("main.exe", "jac"):
        if not os.access(os.path.join(bindir, target), os.X_OK):
            print(f"missing {bindir}/{target}; build with `dune build bin/main.exe bin/jac`", file=sys.stderr)
            return 2
    scratch = os.path.abspath(args.scratch)
    os.makedirs(scratch, exist_ok=True)
    plain = wrappers(os.path.join(scratch, "wrap-plain"), bindir, 0)
    shifted = wrappers(os.path.join(scratch, "wrap-shifted"), bindir, SHIFT)

    if args.crams:
        crams = [os.path.relpath(os.path.abspath(c), REPO) for c in args.crams]
    else:
        crams = []
        for dirpath, dirnames, filenames in os.walk(os.path.join(REPO, "test")):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d != "_build")
            crams += [os.path.relpath(os.path.join(dirpath, f), REPO) for f in sorted(filenames) if f.endswith(".t")]
    changed = changed_lines(args.base) if args.base else None

    failures, checked = [], 0
    for rel in crams:
        cmds = list(blocks(os.path.join(REPO, rel)))
        targets = [
            start
            for start, cmd, span in cmds
            if pinned(cmd) and (changed is None or span & changed.get(rel, set()))
        ]
        if not targets:
            continue
        script = []
        for start, cmd, _ in cmds:
            script.append(f"echo '@@BLOCK {start}'")
            # a transcript's `exit N` ends only its own command; keep the script running
            script.append(re.sub(r'(?<![=\w"])exit (\d+)', r"(exit \1)", cmd))
        script = "\n".join(script) + "\n"
        name = re.sub(r"[^A-Za-z0-9]+", "-", rel[:-2])
        tmp = os.path.join(scratch, "tmp")
        base_out = run_cram(rel, script, plain, os.path.join(scratch, "root-" + name), tmp)
        shift_out = run_cram(rel, script, shifted, os.path.join(scratch, "root-" + name), tmp)
        for start in targets:
            checked += 1
            if start not in base_out or start not in shift_out:
                failures.append(f"{rel}:{start}: block did not run")
            elif base_out[start] == shift_out[start]:
                failures.append(f"{rel}:{start}: output unchanged under the status shift: {base_out[start][:200]!r}")
        print(f"{rel}: {len(targets)} pinned blocks", flush=True)

    print(f"checked {checked} blocks, {len(failures)} not caught")
    for failure in failures:
        print("NOT CAUGHT", failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
