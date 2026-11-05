#!/usr/bin/env python3
"""Mutation check for the exit statuses that cram transcripts pin.

A cram transcript records only a command line's final status, so a command that
runs `jacquard` or `jac` must pin the tool's status itself, typically

    jacquard run x.jac > pipe.out 2>&1 || echo "exit=$?"; head -1 < pipe.out

(test/test_cram_status.ml rejects the masked forms). This check tests the pins.
It runs each cram's commands as one script in a scratch copy of the cram's
directory: twice with the real tools (the two runs must agree, or the cram is
reported as nondeterministic), then once per checked block with `jacquard`/`jac`
wrappers that shift the exit status by 50 (0 -> 50, n -> n + 50) only while
that block runs. Each run's whole output, with every nonzero command status
recorded as `[N]` as in a transcript, and its exit code are compared with the
real run. Because only the checked block is shifted, any difference is caused by
its tools' statuses, whether the block prints it, a later block prints a saved
status, or a skipped command changes what later blocks do. A checked block whose
run is identical to the real run is reported: a failing tool would pass its
transcript.

Limits: the check works per block, so an unpinned tool call is still missed when
another call in the same block changes the output; only blocks that mention
`pipe.out` or `status=$?` are checked; the scratch tree copies the cram's source
directory and links the rest of the checkout, so a cram that needs files dune
generates into _build fails in both runs and is reported.

The check runs the crams themselves, so it is a manual tool, not part of
`dune runtest`. Build first (`dune build bin/main.exe bin/jac`), then:

    scripts/dev/cram-status-mutation.py --base main     # blocks changed since main
    scripts/dev/cram-status-mutation.py test/cli/fuel.t # one cram
    scripts/dev/cram-status-mutation.py                 # every pinned block (hours)

Options: --bindir DIR holds main.exe and jac (default _build/default/bin);
--scratch DIR is a disposable work directory (default
.scratch/tmp/cram-status-mutation). Exit status 0 when every checked block is
caught, 1 otherwise, 2 on a usage error.
"""

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHIFT = 50
TIMEOUT = 3600


def changed_lines(base):
    """Map cram path (repo-relative) -> set of 1-based line numbers changed since BASE.

    A hunk that only deletes lines marks the lines on both sides of the deletion."""
    proc = subprocess.run(["git", "-C", REPO, "diff", "-U0", base, "--", "test"], capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"git diff {base} failed: {proc.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    out = proc.stdout
    res, path = {}, None
    for line in out.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
        if m and path and path.endswith(".t"):
            start, count = int(m.group(1)), int(m.group(2) or 1)
            lines = range(start, start + count) if count else (start, start + 1)
            res.setdefault(path, set()).update(lines)
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


def wrappers(directory, bindir):
    """`jacquard`/`jac` wrappers that shift the real tool's status while the flag file exists."""
    os.makedirs(directory, exist_ok=True)
    flag = os.path.join(directory, "shift-on")
    for tool, target in (("jacquard", "main.exe"), ("jac", "jac")):
        path = os.path.join(directory, tool)
        real = os.path.join(bindir, target)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(
                f'#!/bin/sh\n"{real}" "$@"\ns=$?\n'
                f'if test -e "{flag}"; then exit $((s + {SHIFT})); fi\nexit $s\n'
            )
        os.chmod(path, 0o755)
    return directory, flag


def script_for(cmds, shifted, flag):
    """The cram's commands as one script; the flag file exists only while block SHIFTED runs."""
    out = [f"trap 'rm -f \"{flag}\"' EXIT"]
    for start, cmd, _ in cmds:
        # a leading newline keeps the marker on its own line after output without one
        out.append(f"printf '\\n@@BLOCK {start}\\n'")
        if start == shifted:
            out.append(f"touch '{flag}'")
        out.append(cmd)
        out.append("__s=$?")
        if start == shifted:
            out.append(f"rm -f '{flag}'")
        out.append('if test "$__s" != 0; then echo "[$__s]"; fi')
    return "\n".join(out) + "\n"


def run_cram(rel, script, wrapdir, flag, scratch):
    """Run SCRIPT in a fresh scratch tree; return (exit code, output)."""
    root = os.path.join(scratch, "root")
    tmp = os.path.join(scratch, "tmp")
    try:
        for d in (root, tmp):
            shutil.rmtree(d, ignore_errors=True)
        if os.path.exists(flag):
            os.remove(flag)
        os.makedirs(os.path.join(root, "test"))
        os.makedirs(tmp)
        for entry in os.listdir(REPO):
            if entry not in ("test", "_build", ".git", ".scratch", "_opam"):
                os.symlink(os.path.join(REPO, entry), os.path.join(root, entry))
        top = rel.split(os.sep)[1]
        for entry in os.listdir(os.path.join(REPO, "test")):
            if entry != top:
                os.symlink(os.path.join(REPO, "test", entry), os.path.join(root, "test", entry))
        shutil.copytree(
            os.path.join(REPO, "test", top), os.path.join(root, "test", top), ignore=shutil.ignore_patterns("*.t")
        )
        env = dict(os.environ, PATH=wrapdir + os.pathsep + os.environ["PATH"], NO_COLOR="1", TMPDIR=tmp)
        proc = subprocess.Popen(
            ["sh", "-c", script],
            cwd=os.path.join(root, os.path.dirname(rel)),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        try:
            output, _ = proc.communicate(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            output, _ = proc.communicate()
            return "timeout", output
        return proc.returncode, output
    finally:
        for d in (root, tmp):
            shutil.rmtree(d, ignore_errors=True)
        if os.path.exists(flag):
            os.remove(flag)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
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
    wrapdir, flag = wrappers(os.path.join(scratch, "wrap"), bindir)

    if args.crams:
        crams = [os.path.relpath(os.path.abspath(c), REPO) for c in args.crams]
    else:
        crams = []
        for dirpath, dirnames, filenames in os.walk(os.path.join(REPO, "test")):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d != "_build")
            crams += [os.path.relpath(os.path.join(dirpath, f), REPO) for f in sorted(filenames) if f.endswith(".t")]
    for rel in crams:
        if not (rel.startswith("test" + os.sep) and rel.endswith(".t") and os.path.isfile(os.path.join(REPO, rel))):
            print(f"not a cram file under test/: {rel}", file=sys.stderr)
            return 2
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
        real = run_cram(rel, script_for(cmds, None, flag), wrapdir, flag, scratch)
        again = run_cram(rel, script_for(cmds, None, flag), wrapdir, flag, scratch)
        if real != again:
            failures.append(f"{rel}: the real runs differ (nondeterministic output); {len(targets)} blocks unchecked")
            print(f"{rel}: nondeterministic, skipped", flush=True)
            continue
        for start in targets:
            checked += 1
            if run_cram(rel, script_for(cmds, start, flag), wrapdir, flag, scratch) == real:
                failures.append(f"{rel}:{start}: the run is unchanged under the status shift")
        print(f"{rel}: {len(targets)} checked blocks", flush=True)

    shutil.rmtree(os.path.join(scratch, "wrap"), ignore_errors=True)
    print(f"checked {checked} blocks, {len(failures)} not caught")
    for failure in failures:
        print("NOT CAUGHT", failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
