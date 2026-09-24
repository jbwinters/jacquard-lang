API.1 interface manifests. `jacquard interface emit` checks a source and writes its
interface-v1 manifest: one export per public name with its exact identity, a
name-independent signature, its call labels, and the hidden members of its
declarations. The manifest is the durable API carrier that HASH_V0 and positional
`.jqd` export deliberately omit.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ cat > lib.jac <<'JACQUARD'
  > type Pair a b = | MkPair(left: a, right: b)
  > resize(image, scale: ratio) = (image, ratio)
  > once effect Sending where { send : (path: Text, body: Text) -> Text }
  > JACQUARD
  $ jacquard interface emit lib.jac -o lib.jqi
  $ jacquard interface emit lib.jac | cmp - lib.jqi && echo deterministic
  deterministic
  $ head -2 lib.jqi
  (interface-v1
    (hash-algorithm "HASH_V0"))
  $ grep -c '^(export' lib.jqi
  7
  $ grep -A1 '^  resize$' lib.jqi | tail -1 | sed 's/[0-9a-f]\{64\}/HASH/'
    #HASH
  $ grep 'labels' lib.jqi
    (labels (slot named left) (slot named right)))
    (labels (slot positional) (slot named scale)))
    (labels (slot named path) (slot named body)))

A manifest is never overwritten, and a malformed one is refused.

  $ jacquard interface emit lib.jac -o lib.jqi 2>&1 | grep -o 'error\[E1301\]'
  error[E1301]
  $ printf '(interface-v9 (hash-algorithm "HASH_V0"))\n' > bad.jqi
  $ jacquard interface diff bad.jqi lib.jqi
  error[E0613]: An interface manifest is malformed or unsupported.
    Cause: bad.jqi: expected an `interface-v1` header first, found `interface-v9`
    Next step: Regenerate the manifest with `jacquard interface emit` from the checked source.
  [1]

Renaming binders and reformatting change the source digest only; the API, and the
manifest identity built from it, are unchanged. Changing a call label, a type, or
removing an export is a breaking change; adding one is compatible.

  $ sed 's/resize(image, scale: ratio) = (image, ratio)/resize(img, scale: r) = (img,  r)/' lib.jac > renamed.jac
  $ jacquard interface emit renamed.jac -o renamed.jqi
  $ diff lib.jqi renamed.jqi | grep -c '^[<>]'
  2
  $ jacquard interface diff lib.jqi renamed.jqi
  identical
  $ sed 's/scale: ratio/factor: ratio/' lib.jac > relabeled.jac
  $ jacquard interface emit relabeled.jac -o relabeled.jqi
  $ jacquard interface diff lib.jqi relabeled.jqi
  breaking   term resize: labels (positional, scale:) -> (positional, factor:)
  [1]
  $ (cat lib.jac; echo 'extra = 1') > extended.jac
  $ jacquard interface emit extended.jac -o extended.jqi
  $ jacquard interface diff lib.jqi extended.jqi
  compatible term extra: added
  $ jacquard interface diff extended.jqi lib.jqi
  breaking   term extra: removed
  [1]

`jacquard interface verify` checks that a store provides exactly the interface a
manifest describes. A store holding the declarations passes; one whose companion
labels differ, or that lacks a companion the manifest records, is refused rather
than having its labels inferred.

  $ jacquard run --store provider lib.jac
  $ jacquard interface verify lib.jqi provider
  ok
  $ jacquard interface verify relabeled.jqi provider
  error[E0614]: The store does not provide the interface the manifest describes.
    Cause: provider: term resize carries labels (positional, scale:), not (positional, factor:)
    Next step: Install the manifest's declarations and companions, or regenerate the manifest.
  [1]
  $ jacquard export lib.jac -o lib.jqd
  $ jacquard run --store positional lib.jqd
  $ jacquard interface verify lib.jqi positional 2>&1 | grep 'Cause:'
    Cause: positional: term resize carries no call-abi-v1 companion for labels (positional, scale:)
    Cause: positional: op send carries no call-abi-v1 companion for labels (path:, body:)
  $ jacquard interface verify extended.jqi provider 2>&1 | grep 'Cause:'
    Cause: provider: term extra is not bound
  $ jacquard interface verify lib.jqi nowhere 2>&1 | grep -o 'error\[E0606\]'; test ! -e nowhere && echo not-created
  error[E0606]
  not-created

The command is part of the documented toolchain.

  $ jacquard --help=plain | grep '^       interface '
         interface COMMAND …

Application evidence: `emit` checks one file in a fresh session, so the one
application model that stands alone (the rota optimizer; the other three
depend on `shared/display.jac` and wait for the PKG.1 project workflow) has a
deterministic interface in which its generated accessors are ordinary exports.

  $ A=../../demos/applications
  $ jacquard interface emit $A/rota-optimizer/model.jac -o rota.jqi
  $ jacquard interface emit $A/rota-optimizer/model.jac | cmp - rota.jqi && echo deterministic
  deterministic
  $ grep -c '^(export' rota.jqi
  86
  $ grep -c '^  rota-staff\.\(id\|name\|limit\)$' rota.jqi
  3
