GM14-A carries the unchanged Audit chain beside the exact Governance artifacts
needed to review its identities and links. The verifier reconstructs the
published head, follows transformed-Call ancestry, and accounts for every
artifact without claiming that an external action or rollback happened.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ jacquard governance verify-run governance-run-bundle-v1.jqd
  ok 96042b6dc44c499c3b3f450b0afa7ef2a21591ccd33328825f974bb43d1598d5 entries=4 calls=2 policies=1 assessments=1 proposals=1 consents=1 transformed=1

The artifact identity is recomputed from the unchanged v0 subject encoding. A
forged carried Proposal hash fails closed even though the Audit records remain
individually valid.

  $ sed 's/#c743dec7907499b28565512b4f2b1a2314b700503eb3ef26949c2cf0ebe98fc6/#0000000000000000000000000000000000000000000000000000000000000000/3' governance-run-bundle-v1.jqd > forged-run-bundle-v1.jqd
  $ jacquard governance verify-run forged-run-bundle-v1.jqd
  error[E1501]: A governance artifact is malformed or carries the wrong identity.
    Cause: Proposal artifact 0 carries #0000000000000000000000000000000000000000000000000000000000000000 but canonical governance-proposal-v0 bytes hash to #c743dec7907499b28565512b4f2b1a2314b700503eb3ef26949c2cf0ebe98fc6
    Next step: Restore the exact canonical artifact and its matching carried identity.
  [1]

Bundle bytes are a canonical review artifact: exactly one compact form and a
final LF. Refusing a missing terminator prevents multiple byte renderings of
the same evidence package.

  $ tr -d '\n' < governance-run-bundle-v1.jqd > no-lf-run-bundle-v1.jqd
  $ jacquard governance verify-run no-lf-run-bundle-v1.jqd
  error[E1500]: The governance run bundle is malformed, unsupported, or unsafe to read.
    Cause: no-lf-run-bundle-v1.jqd: governance run bundle must end with LF
    Next step: Regenerate one canonical governance-run-bundle-v1 from stable verified artifacts.
  [1]
