#!/usr/bin/env python3
"""Mutation check for the exit statuses that cram transcripts pin.

A cram transcript records only a command line's final status, so a command that
runs `jacquard` or `jac` must pin the tool's status itself, typically

    jacquard run x.jac > pipe.out 2>&1 || echo "exit=$?"; head -1 < pipe.out

(test/test_cram_status.ml rejects the masked forms). This check tests the pins:
it runs each cram's commands in a scratch copy of the cram's directory, once
with the real tools and then with `jacquard`/`jac` wrappers that shift the exit
status by 50 (0 -> 50, n -> n + 50) only while a checked block runs. Every
pinned block (one that mentions `pipe.out` or `status=$?`) must print something
different, or end with a different status, under the shift; a block whose
output is unchanged would let a failing tool pass its transcript.

A shifted block can change what later blocks start from (a skipped `cd`, file or
assignment), so a checked block counts only when the working directory, shell
variables and scratch files it starts from match the real run; otherwise it is
retried in a further pass. The check works per block: a block whose pinned call
changes its output counts as caught even if another tool call in the same block
is unpinned. Blocks that pin a status without `pipe.out` or `status=$?` are not
selected.

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
    """`jacquard`/`jac` wrappers that shift the real tool's status while FLAG exists."""
    os.makedirs(directory, exist_ok=True)
    flag = os.path.join(directory, "shift-on")
    if os.path.exists(flag):
        os.remove(flag)
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


# The shell state a block starts from: working directory, shell variables (minus ones that differ
# between any two runs) and the scratch tree's files. mktemp names are normalized.
STATE = r"""__state() {
  { pwd; set | grep -v -E '^(PPID|_|RANDOM|SECONDS|LINENO|BASHPID|OPTIND|__s)='
    find "$__root" -type f -exec cksum {} + 2>/dev/null | sort
  } | sed -E 's/tmp\.[A-Za-z0-9]{6,}/tmp.X/g' | cksum
}
"""


def script_for(cmds, targets, shifted, flag, root):
    """The cram's commands as one script; FLAG exists only while a block in SHIFTED runs."""
    out = [f"__root='{root}'", STATE]
    for start, cmd, _ in cmds:
        if start in targets:
            out.append(f"echo \"@@STATE {start} $(__state)\"")
        out.append(f"echo '@@BLOCK {start}'")
        if start in shifted:
            out.append(f"touch '{flag}'")
        # a transcript's `exit N` ends only its own command; keep the script running
        out.append(re.sub(r'(?<![=\w"])exit (\d+)', r"(exit \1)", cmd))
        out.append("__s=$?")
        if start in shifted:
            out.append(f"rm -f '{flag}'")
        out.append('if test "$__s" != 0; then echo "[$__s]"; fi')
    return "\n".join(out) + "\n"


def run_cram(rel, script, wrapdir, root, tmp):
    """Run SCRIPT in a scratch tree mirroring the build layout.

    Returns ({block line: output}, {block line: state digest})."""
    try:
        shutil.rmtree(root, ignore_errors=True)
        os.makedirs(os.path.join(root, "test"))
        for entry in os.listdir(REPO):
            if entry not in ("test", "_build", ".git", ".scratch", "_opam"):
                os.symlink(os.path.join(REPO, entry), os.path.join(root, entry))
        cram_dir = os.path.dirname(rel)
        top = cram_dir.split(os.sep)[1]
        for entry in os.listdir(os.path.join(REPO, "test")):
            if entry != top:
                os.symlink(os.path.join(REPO, "test", entry), os.path.join(root, "test", entry))
        cwd = os.path.join(root, cram_dir)
        shutil.copytree(
            os.path.join(REPO, "test", top), os.path.join(root, "test", top), ignore=shutil.ignore_patterns("*.t")
        )
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
    finally:
        shutil.rmtree(root, ignore_errors=True)
    outputs, states, cur = {}, {}, None
    for line in proc.stdout.splitlines():
        m = re.match(r"@@BLOCK (\d+)$", line)
        st = re.match(r"@@STATE (\d+) (.*)$", line)
        if m:
            cur = int(m.group(1))
            outputs[cur] = []
        elif st:
            states[int(st.group(1))] = st.group(2)
            cur = None
        elif cur is not None:
            outputs[cur].append(line)
    return {k: "\n".join(v) for k, v in outputs.items()}, states


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
    wrapdir, flag = wrappers(os.path.join(scratch, "wrap"), bindir)

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
        name = re.sub(r"[^A-Za-z0-9]+", "-", rel[:-2])
        root = os.path.join(scratch, "root-" + name)
        tmp = os.path.join(scratch, "tmp")
        target_set = set(targets)
        base_out, base_state = run_cram(rel, script_for(cmds, target_set, set(), flag, root), wrapdir, root, tmp)
        # Shift only the checked blocks. A shifted block may change what later blocks start from
        # (a skipped `cd`, file or assignment), so a block's result counts only when its starting
        # state equals the real run's; the first shifted block of a pass always counts. The rest
        # are retried in a further pass.
        pending, passes = list(targets), 0
        while pending:
            passes += 1
            shift_out, shift_state = run_cram(
                rel, script_for(cmds, target_set, set(pending), flag, root), wrapdir, root, tmp
            )
            deferred = []
            for k, start in enumerate(pending):
                if start not in base_out or start not in shift_out:
                    checked += 1
                    failures.append(f"{rel}:{start}: block did not run")
                elif k > 0 and shift_state.get(start) != base_state.get(start):
                    deferred.append(start)
                else:
                    checked += 1
                    if base_out[start] == shift_out[start]:
                        failures.append(
                            f"{rel}:{start}: output unchanged under the status shift: {base_out[start][:200]!r}"
                        )
            pending = deferred
        print(f"{rel}: {len(targets)} pinned blocks, {passes} shifted pass(es)", flush=True)

    shutil.rmtree(os.path.join(scratch, "tmp"), ignore_errors=True)
    print(f"checked {checked} blocks, {len(failures)} not caught")
    for failure in failures:
        print("NOT CAUGHT", failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
