# Host boundary decisions

Status: two decisions are prepared for the owner and remain PENDING. The kit
records both without resolving them; nothing below is approved until this
file says so.

## HBD-1 — `noncanonical-target-hash`: E1603 or E1601

The frozen vector expects E1603 (target invalid) for an uppercase target
identity. Spec section 4 requires exactly 64 lowercase hexadecimal digits and
the fail-fast order in the same section places scalar and envelope shape
(E1601) before target preflight (E1603). The shipped HB.2b2 preflight follows
that order and `test/test_host_invoke_preflight.ml` pins E1601.

Options:

1. Correct the vector to E1601 (spec-consistent; changes a frozen expected
   code, so it is a reviewed protocol-corpus change, not a refresh).
2. Keep E1603 and change preflight to classify malformed identities as target
   failures (contradicts the frozen fail-fast order and an existing pin).
3. Replace the mutation with a well-formed absent identity so the case keeps
   meaning "target absent" (E1603), and add an additive case
   `malformed-target-identity` expecting E1601.

Recommended: option 3. It preserves every existing expectation, adds the
missing malformed-scalar case, and matches both the spec text and the
shipped behavior. Until decided the kit lists the case under
`pending_decisions`.

## HBD-2 — diagnostic prose in vector templates

Two outcome templates (`refused_outcome`, `timeout_unknown_outcome`) carry
illustrative `summary`, `cause`, and `next_step` text that differs from the
prose the shipped session layer emits for E1607 and E1612. Codes, domain,
severity, span, schema, evidence, and the host-message cause suffix agree.

Options:

1. Declare diagnostic prose non-normative in spec section 10 and keep the
   templates as they are (the kit already compares this way).
2. Refresh the two templates from the shipped prose (a vectors change).
3. Freeze the shipped prose in the spec and treat any change as a protocol
   version bump.

Recommended: option 1, with the kit's semantic comparison as the published
rule; prose remains free to improve without a protocol version. Until decided
the kit lists each drifting field under `diagnostic_prose.drift`.
