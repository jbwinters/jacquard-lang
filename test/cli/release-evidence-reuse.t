A release tag reuses an earlier Release Evidence run only when that run was the
Release Evidence workflow started in this repository by a push to a release
branch whose pushed commit is the tagged commit, reproduced it against the same
base, and succeeded (docs/ci-cd.md, Release Evidence). A manual dispatch is
never reused: it runs the code of its ref input, which the run record does not
show. A fake gh serves canned API responses for the exact marker name only;
anything it cannot serve is an API failure, which falls back to a full
reproduction.

  $ find=../../scripts/release/find-prior-evidence.sh
  $ C=1111111111111111111111111111111111111111
  $ S=5555555555555555555555555555555555555555
  $ B=2222222222222222222222222222222222222222
  $ cat > gh <<G
  > #!/bin/sh
  > [ "\$1" = api ] || exit 9
  > shift
  > [ "\$1" = --paginate ] && shift
  > case "\$1" in
  >   "repos/o/r/actions/artifacts?name=release-evidence-pass-$C-$B&per_page=100") f=artifacts.json ;;
  >   repos/o/r/actions/artifacts*) echo '{"artifacts":[]}'; exit 0 ;;
  >   repos/o/r/actions/runs/*) f="run-\${1##*/}.json" ;;
  >   *) exit 9 ;;
  > esac
  > [ -f "\$f" ] || exit 1
  > cat "\$f"
  > G
  $ chmod +x gh && export GH=$PWD/gh
  $ run() {
  >   printf '{"path":"%s","event":"%s","head_branch":"%s","head_sha":"%s","conclusion":"%s","head_repository":{"full_name":"%s"}}\n' \
  >     "$2" "$3" "$4" "$5" "$6" "$7" > "run-$1.json"
  > }
  $ artifacts() {
  >   printf '{"artifacts":[' > artifacts.json
  >   sep=
  >   for a in "$@"; do
  >     printf '%s{"expired":%s,"workflow_run":{"id":%s}}' "$sep" "${a##*:}" "${a%:*}" >> artifacts.json
  >     sep=,
  >   done
  >   printf ']}\n' >> artifacts.json
  > }
  $ W=.github/workflows/release-evidence.yml

No marker, an API failure, or a marker for another commit or base finds
nothing:

  $ artifacts
  $ $find o/r $C $B; echo "exit $?"
  exit 1
  $ rm artifacts.json
  $ $find o/r $C $B; echo "exit $?"
  exit 1
  $ run 10 $W@refs/heads/release/0.4 push release/0.4 $C success o/r
  $ artifacts 10:false
  $ $find o/r $S $B; echo "exit $?"
  exit 1
  $ $find o/r $C 3333333333333333333333333333333333333333; echo "exit $?"
  exit 1

A successful push of the tagged commit to a release branch is reused,
including when the API reports the workflow path with its ref:

  $ $find o/r $C $B; echo "exit $?"
  10
  exit 0

Each rejected run is skipped, and the first acceptable one wins: a pull
request, another workflow, a manual dispatch (even from main, of the tagged
commit), a push to a branch that is not a release branch, a push of another
commit, a failed run, another repository, an unreadable run, a run id that is
not a number, and an expired marker.

  $ run 11 $W pull_request release/0.4 $C success o/r
  $ run 12 .github/workflows/ci.yml push release/0.4 $C success o/r
  $ run 13 $W workflow_dispatch main $C success o/r
  $ run 14 $W push main $C success o/r
  $ run 15 $W push release/0.4 $S success o/r
  $ run 16 $W push release/0.4 $C failure o/r
  $ run 17 $W push release/0.4 $C success fork/r
  $ run 10abc $W push release/0.4 $C success o/r
  $ run 19 $W push release/0.4 $C success o/r
  $ artifacts 10:true 11:false 12:false 13:false 14:false 15:false 16:false 17:false 18:false '"10abc"':false 19:false
  $ $find o/r $C $B; echo "exit $?"
  19
  exit 0
  $ artifacts 10:true 11:false 12:false 13:false 14:false 15:false 16:false 17:false 18:false '"10abc"':false
  $ $find o/r $C $B; echo "exit $?"
  exit 1

Malformed arguments are usage errors:

  $ $find o/r $C; echo "exit $?"
  usage: find-prior-evidence.sh <repo> <commit> <base>
  exit 2
  $ $find o/r main $B; echo "exit $?"
  commit and base must be full lowercase hex object names
  exit 2
  $ $find o/r abc123 $B; echo "exit $?"
  commit and base must be full lowercase hex object names
  exit 2
  $ $find o/r $C abc123; echo "exit $?"
  commit and base must be full lowercase hex object names
  exit 2
  $ $find o/r gggggggggggggggggggggggggggggggggggggggg $B; echo "exit $?"
  commit and base must be full lowercase hex object names
  exit 2
  $ $find o/r $C AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; echo "exit $?"
  commit and base must be full lowercase hex object names
  exit 2
