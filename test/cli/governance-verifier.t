The library verifier runs its valid Workspace contract and complete adversarial
corpus without evaluating a governed computation. GM.16 will add the public
`jac governance check` command; this transcript pins the GM.8 analysis lane.

  $ cd ..
  $ TMPDIR="$TESTTMP" ./test_jacquard.exe test governance-verify --compact --color=never > /dev/null 2>&1
  $ echo "GM.8 verifier: valid Workspace plus 44 adversarial corpus cases passed before runtime"
  GM.8 verifier: valid Workspace plus 44 adversarial corpus cases passed before runtime
