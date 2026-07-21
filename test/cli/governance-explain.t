GM.17A is an offline, proposal-scoped review surface. It fully verifies the
canonical reconciliation package before stdout and then projects the exact
Proposal, Call, authority, policy, assessment, recomputed live rule, Decision,
ordered Audit records, and canonical committed Workspace driver.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ mkdir gm17a-tmp
  $ export TMPDIR=$PWD/gm17a-tmp
  $ proposal=c743dec7907499b28565512b4f2b1a2314b700503eb3ef26949c2cf0ebe98fc6
  $ jac governance explain "$proposal" --bundle governance-explain-approved-v1.jqd > approved.text 2> approved.err
  $ wc -c < approved.err
  0
  $ grep -E '^(ok |review-facts-schema|proposal-id|operation |policy-rule|recorded-verdict|decision-kind|attempt-state|driver |receipt-id|evidence-limit)' approved.text
  ok governance-explain-v1 schema=jacquard-governance-explain-report-v1
  review-facts-schema jacquard-governance-review-facts-v1
  proposal-id #c743dec7907499b28565512b4f2b1a2314b700503eb3ef26949c2cf0ebe98fc6
  operation workspace.write-file #73140dde8e33c268fa589d9bfaeb28b156af2da52b22779257b2d3e9b696b03c
  policy-rule live.at-or-below-ask
  recorded-verdict ask
  decision-kind approved
  attempt-state reconciled-completed
  driver workspace.driver-write #c25559992f4ed35eb5bdd244430124478fc554b2c8d75ac5d19230982dadeb88
  receipt-id #ab85645a1055d99296b8b1a158a9db184dbd9b723fffe39ddeeeaa141e25e48a
  evidence-limit committed-driver-not-execution-proof
  evidence-limit external-receipt-digest-not-receipt-truth
  evidence-limit resource-scope-not-type-proof
  evidence-limit missing-completion-not-rollback

Text and json-v1 are deterministic projections of the same verified report.
The nested facts object is the A-available dynamic input for later review
classification; it deliberately contains no simulator or provenance guesses.

  $ jac governance explain "$proposal" --bundle governance-explain-approved-v1.jqd > approved-again.text
  $ cmp approved.text approved-again.text
  $ jac governance explain "$proposal" --bundle governance-explain-approved-v1.jqd --output-format json-v1 > approved.json
  $ jac governance explain "$proposal" --bundle governance-explain-approved-v1.jqd --output-format json-v1 > approved-again.json
  $ cmp approved.json approved-again.json
  $ sed -E 's/^\{"schema":"([^"]+)".*/schema \1/' approved.json
  schema jacquard-governance-explain-report-v1
  $ sed -E 's/.*"review_facts":\{"schema":"([^"]+)".*/review-facts-schema \1/' approved.json
  review-facts-schema jacquard-governance-review-facts-v1
  $ text_proposal=$(sed -n 's/^proposal-id #//p' approved.text); json_proposal=$(sed -E 's/.*"proposal_id":"([^"]+)".*/\1/' approved.json); test "$text_proposal" = "$json_proposal"
  $ text_rule=$(sed -n 's/^policy-rule //p' approved.text); json_rule=$(sed -E 's/.*"policy_rule":"([^"]+)".*/\1/' approved.json); test "$text_rule" = "$json_rule"

Denied and escalated Decisions do not acquire a driver by inference. This
canonical denied package therefore renders the non-action state explicitly.

  $ jac governance explain "$proposal" --bundle governance-explain-denied-v1.jqd | grep -E '^(decision-kind|attempt-state|attempt-id|driver |receipt-id)'
  decision-kind denied
  attempt-state not-attempted
  attempt-id not-attempted
  driver not-attempted
  receipt-id not-attempted

Malformed or absent selection, a noncanonical committed driver, and byte
tampering all fail before stdout. Output and diagnostic formats are independent.

  $ jac governance explain AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA --bundle governance-explain-approved-v1.jqd --output-format json-v1 --diagnostic-format json-v1 > malformed.out 2> malformed.err; echo $?
  1
  $ wc -c < malformed.out
  0
  $ cat malformed.err
  {"schema":"jacquard-diagnostic-v1","domain":"governance","code":"E1530","severity":"error","span":null,"summary":"The proposal identifier is not canonical HASH_V0 text.","cause":"Proposal ID must be exactly 64 lowercase hexadecimal digits","next_step":"Pass exactly 64 lowercase hexadecimal HASH_V0 digits."}
  $ jac governance explain 0000000000000000000000000000000000000000000000000000000000000000 --bundle governance-explain-approved-v1.jqd > missing.out 2> missing.err; echo $?
  1
  $ wc -c < missing.out
  0
  $ sed -n '1p' missing.err
  error[E1531]: The verified reconciliation package cannot select one linked Proposal.
  $ jac governance explain "$proposal" --bundle governance-reconciliation-v1.jqd > wrong-driver.out 2> wrong-driver.err; echo $?
  1
  $ wc -c < wrong-driver.out
  0
  $ sed -n '1p' wrong-driver.err
  error[E1533]: The Workspace action evidence cannot support this explanation.
  $ sed 's/#c25559992f4ed35eb5bdd244430124478fc554b2c8d75ac5d19230982dadeb88/#0000000000000000000000000000000000000000000000000000000000000000/' governance-explain-approved-v1.jqd > tampered.jqd
  $ jac governance explain "$proposal" --bundle tampered.jqd > tampered.out 2> tampered.err; echo $?
  1
  $ wc -c < tampered.out
  0
  $ sed -n '1p' tampered.err
  error[E1511]: The action journal chain or published head is inconsistent.
