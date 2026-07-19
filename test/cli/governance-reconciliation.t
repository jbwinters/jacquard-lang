GM14-B keeps action evidence separate from the frozen Audit v2 stream. A
durable attempt names the exact Allow or Approved Audit record, and a typed
receipt binds the same Call, branch, and outcome as Completed.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ jacquard governance reconcile governance-reconciliation-v1.jqd
  ok audit=96042b6dc44c499c3b3f450b0afa7ef2a21591ccd33328825f974bb43d1598d5 journal=540a0c1e4f4eb1b0610f90a57602176ebfcd5a2a3cd593e8e00b40165a0a24e4 no-action-legal=1 authorized-not-observed=0 unknown=0 receipt-gap=0 complete=1 completion-without-receipt=0

A structurally valid package can still require operator work. Here the Audit
stream has an authorization and live completion, while the action journal has
neither an attempt nor a receipt. Both gaps remain visible; neither is
rewritten into the claim that no external action happened.

  $ jacquard governance reconcile governance-reconciliation-gap-v1.jqd
  reconciliation-needed audit=96042b6dc44c499c3b3f450b0afa7ef2a21591ccd33328825f974bb43d1598d5 journal=0ddca6fab318d0de125e7bfea1357c1c5acfc8c1b0052344cd331bc8004108ff no-action-legal=1 authorized-not-observed=1 unknown=0 receipt-gap=0 complete=0 completion-without-receipt=1
  error[E1516]: Action evidence still requires operator reconciliation
    Cause: Valid action evidence still requires operator reconciliation; no rollback or safe retry is implied.
    Next step: Reconcile the remaining action evidence before retrying or rolling back.
  [1]

The journal chain commits exact action-subject bytes. Changing a carried
attempt ID breaks the record digest before the forged identity can be used.

  $ sed 's/#674300d440924d7f1400f3fab2e5f0bfe4c13dcda3224dfab9f691ddbd3372b4/#0000000000000000000000000000000000000000000000000000000000000000/' governance-reconciliation-v1.jqd > forged-reconciliation-v1.jqd
  $ jacquard governance reconcile forged-reconciliation-v1.jqd
  error[E1511]: The action journal chain or published head is inconsistent.
    Cause: action journal record 0 has a mismatched digest
    Next step: Restore the original predecessor-linked journal and its independently published head.
  [1]

  $ tr -d '\n' < governance-reconciliation-v1.jqd > no-lf-reconciliation-v1.jqd
  $ jacquard governance reconcile no-lf-reconciliation-v1.jqd
  error[E1510]: The governance reconciliation bundle is malformed, unsupported, or unsafe to read.
    Cause: no-lf-reconciliation-v1.jqd: governance reconciliation bundle must end with LF
    Next step: Regenerate one canonical governance-reconciliation-bundle-v1 from stable evidence.
  [1]
