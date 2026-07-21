GM.17B exposes one top-level, source-only attribution command. Success is
deterministic and never claims execution provenance.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ mkdir gm17b-tmp
  $ export TMPDIR=$PWD/gm17b-tmp

  $ jac why-effect Fs --source ../../corpus/governance/workspace-why-effect-direct.jqd --output-format json-v1 > fs.json
  $ grep -o '"operation":{"name":"workspace\.[^"]*"' fs.json
  "operation":{"name":"workspace.read-file"
  "operation":{"name":"workspace.read-file"
  "operation":{"name":"workspace.write-file"
  "operation":{"name":"workspace.read-file"
  "operation":{"name":"workspace.write-file"
  "operation":{"name":"workspace.read-file"
  "operation":{"name":"workspace.read-file"
  "operation":{"name":"workspace.write-file"
  $ grep -o '"application_site":{"member":{[^}]*},"ordinal":[0-9]*}' fs.json | sed 's/.*"ordinal"://; s/}//'
  0
  2
  4
  0
  2
  4
  $ grep -o '"schema":"jacquard-[^"]*"' fs.json
  "schema":"jacquard-why-effect-report-v1"
  "schema":"jacquard-governance-review-facts-v1"
  $ grep -o '"execution_provenance":false' fs.json
  "execution_provenance":false
  $ jac why-effect Fs --source ../../corpus/governance/workspace-why-effect-direct.jqd --output-format json-v1 > fs-again.json
  $ cmp fs.json fs-again.json

Net and Secret both select fetch, while the exact released hash is equivalent
to its blessed display name.

  $ for effect in Net Secret; do jac why-effect "$effect" --source ../../corpus/governance/workspace-why-effect-direct.jqd --output-format json-v1 | grep -o '"operation":{"name":"workspace.fetch"' | wc -l | tr -d ' '; done
  3
  3
  $ jac why-effect 8ec13169c7181851364e55353232af8e3c7f5ee4a010fa3067fcf2058dd5ed84 --source ../../corpus/governance/workspace-why-effect-direct.jqd --output-format json-v1 > fs-hash.json
  $ cmp fs.json fs-hash.json
  $ jac why-effect Fs --source ../../corpus/governance/workspace-why-effect-direct.jac --output-format json-v1 > fs-surface.json
  $ cmp fs.json fs-surface.json

The source identity graph follows a GroupRef wrapper. Fully verified source
with no matching application succeeds with a deterministic empty list; direct
dry roots are also zero-chain.

  $ jac why-effect Fs --source ../../corpus/governance/workspace-why-effect-wrapper.jqd | sed -n '2p'
  facade Workspace #d5831f495fdb26e05d53d886786f07230f7bb808ac4933ab32e0a9238c89f9d0 operations=workspace.read-file #632071e3399c913a672c4bea7d4a8b394e64a9a517552eb296db824222fe2da1,workspace.write-file #73140dde8e33c268fa589d9bfaeb28b156af2da52b22779257b2d3e9b696b03c,workspace.fetch #f6536683575508ddcc2d5a6509df832e92897cbef2caf34219f993a110079b01
  $ jac why-effect Fs --source ../../corpus/governance/workspace-why-effect-wrapper.jqd | grep '^chain ' | grep 'workspace-why-effect-wrapper' | grep 'workspace-why-effect-helper' >/dev/null
  $ for source in workspace-check-zero-layer.jqd workspace-check-dry.jqd workspace-why-effect-dry-ambiguous.jqd; do jac why-effect Fs --source ../../corpus/governance/$source --output-format json-v1 | grep -o '"chains":\[\]' | wc -l | tr -d ' '; done
  1
  1
  1
  $ jac why-effect Fs --source ../../corpus/governance/workspace-why-effect-forwarded.jqd | grep '^chain ' | grep -o 'layer=workspace[^ ]*\|live=workspace[^ ]*'
  layer=workspace.forward-layer
  layer=workspace.forward-layer
  live=workspace.live-layer
  $ for source in workspace-why-effect-unquote.jqd workspace-why-effect-direct-lambda.jqd workspace-why-effect-inert.jqd; do jac why-effect Fs --source ../../corpus/governance/$source --output-format json-v1 | grep -o '"operation":{"name":"workspace.read-file"' | wc -l | tr -d ' '; done
  3
  3
  0
  $ for source in workspace-why-effect-ref-chain.jqd workspace-why-effect-scc.jqd; do jac why-effect Fs --source ../../corpus/governance/$source | grep '^chain ' | sed 's/ operation=.*//' | awk -F' -> ' '{ print NF }'; done
  3
  3

Unsupported effects, variable call transport, and local Workspace handlers
refuse the entire report. Diagnostic and success formats remain independent.

  $ jac why-effect fs --source ../../corpus/governance/workspace-check-zero-layer.jqd --output-format json-v1 --diagnostic-format json-v1 > refused.out 2> refused.err; printf 'exit=%s stdout=%s code=%s\n' "$?" "$(wc -c < refused.out)" "$(grep -o '"code":"E1534"' refused.err | wc -l | tr -d ' ')"
  exit=1 stdout=0 code=1
  $ for source in workspace-why-effect-variable.jqd workspace-why-effect-selected-callable.jqd workspace-why-effect-polymorphic-transport.jqd workspace-why-effect-local-handler.jqd; do jac why-effect Fs --source ../../corpus/governance/$source --output-format json-v1 --diagnostic-format json-v1 > refused.out 2> refused.err; printf '%s exit=%s stdout=%s code=%s\n' "$source" "$?" "$(wc -c < refused.out)" "$(grep -o '"code":"E153[56]"' refused.err | wc -l | tr -d ' ')"; done
  workspace-why-effect-variable.jqd exit=1 stdout=0 code=1
  workspace-why-effect-selected-callable.jqd exit=1 stdout=0 code=1
  workspace-why-effect-polymorphic-transport.jqd exit=1 stdout=0 code=1
  workspace-why-effect-local-handler.jqd exit=1 stdout=0 code=1
  $ jac why-effect fs --source ../../corpus/governance/workspace-check-zero-layer.jqd --output-format json-v1 > refused.out 2> refused.text; printf 'stdout=%s text-E1534=%s\n' "$(wc -c < refused.out)" "$(grep -o 'error\[E1534\]' refused.text | wc -l | tr -d ' ')"
  stdout=0 text-E1534=1
  $ jac why-effect 49648e594a9e79b0bf6e0b73f860c43fc5d816393022eca5f263c2eb6c00dec2 --source ../../corpus/governance/workspace-check-zero-layer.jqd --diagnostic-format json-v1 > refused.out 2> refused.err; printf 'user-fs-hash exit=%s stdout=%s E1534=%s\n' "$?" "$(wc -c < refused.out)" "$(grep -o '"code":"E1534"' refused.err | wc -l | tr -d ' ')"
  user-fs-hash exit=1 stdout=0 E1534=1
  $ for source in workspace-why-effect-same-name.jqd workspace-why-effect-shadow-driver.jqd; do jac why-effect Fs --source ../../corpus/governance/$source --diagnostic-format json-v1 > refused.out 2> refused.err; printf '%s exit=%s stdout=%s E1400=%s\n' "$source" "$?" "$(wc -c < refused.out)" "$(grep -o '"code":"E1400"' refused.err | wc -l | tr -d ' ')"; done
  workspace-why-effect-same-name.jqd exit=1 stdout=0 E1400=1
  workspace-why-effect-shadow-driver.jqd exit=1 stdout=0 E1400=1
