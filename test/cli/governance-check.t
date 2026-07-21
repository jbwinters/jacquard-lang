GM.16 checks one declaration-only canonical Workspace composition in an isolated
analysis store. The successful report pins the facade, exact introduced rows,
policy binders, ordered layers, operation identities, and the separate runtime
verification handoff.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ mkdir gm16-tmp
  $ export TMPDIR=$PWD/gm16-tmp
  $ jac governance check ../../corpus/governance/workspace-check-v1.jqd > valid.text 2> valid.err
  $ wc -c < valid.err
  0
  $ cat valid.text
  ok governance-check-v1 profile=workspace-v0
  facade Workspace #d5831f495fdb26e05d53d886786f07230f7bb808ac4933ab32e0a9238c89f9d0 introduced-row={Workspace}
  live workspace.live #804dfb7bc41dbdcd69e4ae88cb26254603f0c20e6788cc5965515dd51c2e82c6 introduced-row={Audit, GovernanceApprovalV1, Secret, Fs, Judge, Net}
  dry workspace.dry-run #23f0c5350589521c4a7ac89f574911626335401ed1b1677c519b5c554cff5c1f introduced-row={Audit, Judge}
  policy-binders live=#755bd671a2a5651957aff7cf5e902a71fc01153e15ba374c40694f464f4079ff dry=#6b7f57ef2002a375b55d4ea43a94f8f1a4d363456416b95e7c411b3c8e48122b
  layer workspace.forward-layer #41cd84e0b367b5978f1170ff7709514fe52555ffd23799c7b6d79262002e897c introduced-row={Audit, GovernanceApprovalV1, State, Judge, Workspace}
  layer workspace.live-layer #8a6cf8b608942f610041d3218c29a87ebe3be2d0b862a673d4d193bb7616c7da introduced-row={Audit, GovernanceApprovalV1, State, Secret, Fs, Judge, Net}
  operation workspace.read-file #632071e3399c913a672c4bea7d4a8b394e64a9a517552eb296db824222fe2da1 authority=[Fs] normalizer=#e487b3e43c0408d30a42b7e67a7fdecbe596f9c361e78998992635435d4321f1 summarizer=#45035443af0182338269c3d359e4f8ed7e6f2d03ef99e9291b6db6e1838e66d2
  operation workspace.write-file #73140dde8e33c268fa589d9bfaeb28b156af2da52b22779257b2d3e9b696b03c authority=[Fs] normalizer=#224046671b81384fe5adfd663232f34c173c80b862d237c3351dec316e736ada summarizer=#889f02313cbff80d7d1ad540954f8821929f5cf7921aa7d2732b78ea30bc21d4
  operation workspace.fetch #f6536683575508ddcc2d5a6509df832e92897cbef2caf34219f993a110079b01 authority=[Net, Secret] normalizer=#318f57cd05bcf7e22859f25606fa221e5b3671a02c06b89774142d5ed7e4328b summarizer=#2f37080340bbe76a4b92d2ed47598bd635ab0a2a6870a4d1fb72caa87bb55850
  runtime-identities dynamic verify-with="jac governance verify-run BUNDLE"

Text and compact json-v1 are byte-deterministic. Surface and bootstrap carriers
produce the same versioned JSON contract.

  $ jac governance check ../../corpus/governance/workspace-check-v1.jqd > valid-again.text
  $ cmp valid.text valid-again.text
  $ jac governance check ../../corpus/governance/workspace-check-v1.jqd --output-format json-v1 > valid.jqd.json
  $ jac governance check ../../corpus/governance/workspace-check-v1.jac --output-format json-v1 > valid.jac.json
  $ cmp valid.jqd.json valid.jac.json
  $ sha256sum valid.jqd.json | cut -d ' ' -f 1
  243addd3fffa823cde6fd027252c05e566d907802aaa67cc7db92f67433761ac
  $ find "$TMPDIR" -maxdepth 1 -type d -name 'jacquard-governance-*.analysis' | wc -l
  0

The accepted grammar has exact recursive layer cardinality: direct dry and live
have no layer records; one and two forwarding handlers report the forwards
followed by the live leaf, inner-to-outer.

  $ for f in workspace-check-dry.jqd workspace-check-zero-layer.jqd workspace-check-v1.jqd workspace-check-two-layer.jqd; do jac governance check ../../corpus/governance/$f | awk -v file=$f '/^layer / { n++ } END { print file, n + 0 }'; done
  workspace-check-dry.jqd 0
  workspace-check-zero-layer.jqd 0
  workspace-check-v1.jqd 2
  workspace-check-two-layer.jqd 3

The analysis store is disposable and independent of a nearby persistent store.
The command has no --store option and does not alter existing persistent bytes.

  $ printf '(defterm ((binding stable-marker () (lit "stable"))))\n' > stable-marker.jqd
  $ jac store add persistent-store stable-marker.jqd > /dev/null
  $ find persistent-store -type f -exec sha256sum {} + | sort | sha256sum | cut -d ' ' -f 1 > store.before
  $ find ../../prelude -type f -name '*.jqd' -exec sha256sum {} + | sort | sha256sum | cut -d ' ' -f 1 > prelude.before
  $ sha256sum ../../corpus/governance/workspace-check-v1.jqd ../../corpus/governance/workspace-check-v1.jac > source.before
  $ jac governance check ../../corpus/governance/workspace-check-v1.jqd > /dev/null
  $ find persistent-store -type f -exec sha256sum {} + | sort | sha256sum | cut -d ' ' -f 1 > store.after
  $ find ../../prelude -type f -name '*.jqd' -exec sha256sum {} + | sort | sha256sum | cut -d ' ' -f 1 > prelude.after
  $ sha256sum ../../corpus/governance/workspace-check-v1.jqd ../../corpus/governance/workspace-check-v1.jac > source.after
  $ cmp store.before store.after
  $ cmp prelude.before prelude.after
  $ cmp source.before source.after
  $ jac governance check ../../corpus/governance/workspace-check-v1.jqd --store persistent-store > /dev/null 2>&1
  [124]

Eval remains prohibited even beneath a local handler, through a same-group
GroupRef, or in a live unquote splice. The local-handler case deliberately
accumulates both the performed and handled operation identities.

  $ for f in workspace-check-eval.jqd workspace-check-groupref-eval.jqd workspace-check-unquote.jqd; do jac governance check ../../corpus/governance/$f --diagnostic-format json-v1 > hostile.out 2> hostile.err; status=$?; printf '%s exit=%s stdout=%s E1412=%s\n' "$f" "$status" "$(wc -c < hostile.out)" "$(grep -o '"code":"E1412"' hostile.err | wc -l)"; done
  workspace-check-eval.jqd exit=1 stdout=0 E1412=2
  workspace-check-groupref-eval.jqd exit=1 stdout=0 E1412=1
  workspace-check-unquote.jqd exit=1 stdout=0 E1412=1

Raw Fs, Net, and Secret operations outside the trusted exact-hash Workspace
boundary are refused with the routing next step.

  $ for f in workspace-check-raw-fs.jqd workspace-check-raw-net.jqd workspace-check-raw-secret.jqd; do jac governance check ../../corpus/governance/$f --diagnostic-format json-v1 > hostile.out 2> hostile.err; status=$?; printf '%s exit=%s stdout=%s E1407=%s route=%s\n' "$f" "$status" "$(wc -c < hostile.out)" "$(grep -o '"code":"E1407"' hostile.err | wc -l)" "$(grep -c 'Route world actions through the canonical Workspace facade' hostile.err)"; done
  workspace-check-raw-fs.jqd exit=1 stdout=0 E1407=1 route=1
  workspace-check-raw-net.jqd exit=1 stdout=0 E1407=1 route=1
  workspace-check-raw-secret.jqd exit=1 stdout=0 E1407=1 route=1

Closed residual effects cannot hide behind the fixed report. Both a canonical
Console operation and a source-defined effect change the governed root's exact
outward row, so the v1 contract fails closed with E1413.

  $ for f in workspace-check-residual-console.jqd workspace-check-residual-custom.jqd; do jac governance check ../../corpus/governance/$f --diagnostic-format json-v1 > hostile.out 2> hostile.err; status=$?; printf '%s exit=%s stdout=%s E1413=%s exact-row=%s\n' "$f" "$status" "$(wc -c < hostile.out)" "$(grep -o '"code":"E1413"' hostile.err | wc -l)" "$(grep -c 'fixed report can make no truthful claim unless it is exactly' hostile.err)"; done
  workspace-check-residual-console.jqd exit=1 stdout=0 E1413=1 exact-row=1
  workspace-check-residual-custom.jqd exit=1 stdout=0 E1413=1 exact-row=1

Gate-owned Audit and State operation identities are also forbidden in
source-owned bodies. The exact with-sequence and membrane boundaries remain
trusted stops, so their internal control effects do not taint the valid report.

  $ for f in workspace-check-control-audit.jqd workspace-check-control-state.jqd; do jac governance check ../../corpus/governance/$f --diagnostic-format json-v1 > hostile.out 2> hostile.err; status=$?; printf '%s exit=%s stdout=%s E1408=%s gate=%s\n' "$f" "$status" "$(wc -c < hostile.out)" "$(grep -o '"code":"E1408"' hostile.err | wc -l)" "$(grep -c 'Keep Audit, GovernanceApprovalV1, Judge, and State behind the canonical governance gates' hostile.err)"; done
  workspace-check-control-audit.jqd exit=1 stdout=0 E1408=1 gate=1
  workspace-check-control-state.jqd exit=1 stdout=0 E1408=2 gate=2

Generic inspection is rejected independently, and mutable-name shadowing cannot
replace the exact pinned live membrane even when the source root uses its hash.

  $ jac governance check ../../corpus/governance/workspace-check-debug-inspect.jqd --diagnostic-format json-v1 > hostile.out 2> hostile.err; printf 'exit=%s stdout=%s E1409=%s secret-next-step=%s\n' "$?" "$(wc -c < hostile.out)" "$(grep -o '"code":"E1409"' hostile.err | wc -l)" "$(grep -c 'Remove generic inspection and keep Secret values out of review or serialized data' hostile.err)"
  exit=1 stdout=0 E1409=1 secret-next-step=1
  $ jac governance check ../../corpus/governance/workspace-check-shadow-live.jqd --diagnostic-format json-v1 > hostile.out 2> hostile.err; printf 'exit=%s stdout=%s E1400=%s\n' "$?" "$(wc -c < hostile.out)" "$(grep -o '"code":"E1400"' hostile.err | wc -l)"
  exit=1 stdout=0 E1400=1

Missing, ambiguous, inert, open, or miswired roots fail the exact E1413 source
contract instead of treating mutable-name references as proof.

  $ for f in workspace-check-open-tail.jqd workspace-check-ambiguous.jqd workspace-check-inert-reference.jqd workspace-check-wrong-binder.jqd workspace-check-extra-boundary.jqd; do jac governance check ../../corpus/governance/$f --diagnostic-format json-v1 > hostile.out 2> hostile.err; status=$?; printf '%s exit=%s stdout=%s E1413=%s\n' "$f" "$status" "$(wc -c < hostile.out)" "$(grep -o '"code":"E1413"' hostile.err | wc -l)"; done
  workspace-check-open-tail.jqd exit=1 stdout=0 E1413=1
  workspace-check-ambiguous.jqd exit=1 stdout=0 E1413=1
  workspace-check-inert-reference.jqd exit=1 stdout=0 E1413=1
  workspace-check-wrong-binder.jqd exit=1 stdout=0 E1413=1
  workspace-check-extra-boundary.jqd exit=1 stdout=0 E1413=1

Top-level expressions are rejected before evaluation. The cram-local sentinel
demonstrates that no filesystem handler runs.

  $ test ! -e gm16-world-sentinel
  $ jac governance check ../../corpus/governance/workspace-check-expression.jqd --diagnostic-format json-v1 > expression.out 2> expression.err
  [1]
  $ printf 'stdout=%s E1413=%s sentinel=%s\n' "$(wc -c < expression.out)" "$(grep -o '"code":"E1413"' expression.err | wc -l)" "$([ -e gm16-world-sentinel ] && echo present || echo absent)"
  stdout=0 E1413=1 sentinel=absent

Output format and diagnostic format are independent, and unsupported output
values remain ordinary CLI usage errors.

Expected source I/O failures use the stable E1413 stream contract and do not
leak the randomized private analysis-directory name. The existing analysis
parent directory is intentionally supplied where a source file is required.

  $ jac governance check "$TMPDIR" --diagnostic-format json-v1 > source-io.out 2> source-io.err
  [1]
  $ printf 'stdout=%s E1413=%s random-analysis-path=%s\n' "$(wc -c < source-io.out)" "$(grep -o '"code":"E1413"' source-io.err | wc -l)" "$(grep -c 'jacquard-governance-' source-io.err)"
  stdout=0 E1413=1 random-analysis-path=0

  $ jac governance check ../../corpus/governance/workspace-check-v1.jqd --output-format future > /dev/null 2>&1
  [124]
