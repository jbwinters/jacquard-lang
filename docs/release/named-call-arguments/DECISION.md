# SX.23 Named Call Arguments Decision

- Decision date: 2026-08-19
- Reconstruction base: `0509eddd56d88ec492f67ae45c66a332a606bbcb`
- Release posture: post-0.2 successor research prototype

## Decision

Ship explicit named arguments for direct surface callables at the D76 boundary.
Keep the kernel, `HASH_V0`, evaluator, native ABI, and bootstrap `.jqd` grammar
unchanged. Treat term and operation labels as a versioned, identity-bound
surface API rather than inferring them from alpha-renamable binder names.

The supported declaration and call shapes are:

```jacquard
resize(image, scale: ratio) = (image, ratio)

type Packet = | Packet(Int, body: Text)

once effect Sending where {
  send : (path: Text, body: Text) -> Text
}

resize(photo, scale: 2)
Packet(200, body: "ok")
```

An unlabeled positional prefix may precede a labeled suffix. Labeled call
arguments may be authored in any order, but every slot is supplied exactly
once. There are no defaults, label puns, partial calls, or positional arguments
after the first label. A declaration label must select a simple variable
parameter; the label and binder are distinct.

Eligible callees are direct top-level terms, constructors, and effect
operations. Constructors reuse their field schema. Terms and operations expose
an explicit `call-abi-v1` slot vector keyed by their exact derived hash.
Same-SCC term calls use the same contract. Local functions, anonymous or
higher-order callees, patterned parameters, variadics, unlabeled callables, and
opaque identities without a companion fail closed with E0309.

## Semantics And Identity

Resolution elaborates named syntax to the existing positional kernel. A call
already in declaration order becomes an ordinary `App`. A reordered call
becomes left-to-right `Let` bindings in authored order followed by a
declaration-order `App`. Each argument therefore evaluates once in source order
in both the interpreter and native backend.

The declaration-order named spelling hashes exactly like its positional twin;
the reordered spelling hashes like the equivalent explicit-let positional
program. Call labels themselves are erased with surface metadata before kernel
hashing. The external API is nevertheless durable: `names.jqd` stores the
additive, versioned `call-abi-v1` companion. Reopen and public-name or
local-binder renames preserve it. A different vector for the same callable
hash is rejected transactionally with E0612.

Constructor field labels remain part of the constructor schema and content
identity. This decision does not add record types or generated accessors.

## Compatibility Boundary

- Existing positional `.jac` and all `.jqd` programs keep their current
  meaning and hashes.
- Existing stores without companions remain readable. Their unlabeled terms
  and operations remain positional-only.
- `jac export` emits only positional `.jqd`. It preserves the elaborated
  program's hashes and behavior, but does not carry a companion that would let
  a later `.jac` file rediscover labels.
- Kernel semantic diff does not compare store companions; API review that
  includes external labels must inspect the name index.
- Named calls anywhere inside a surface quote, including a live `unquote`, are
  E1238 because quoted code has no durable label carrier. Positional quoted
  calls and raw `.jqd` quotes are unchanged.

## Diagnostics And Review Guidance

E0309-E0314 distinguish unsupported/unlabeled callees, unknown labels,
duplicate or overlapping slots, incomplete arity, invalid declarations, and
ambiguous constructor schemas. E0612 protects persistent API identity. E1238
protects quote round-tripping. Parser ordering errors remain E1220.

When a direct term/operation API exposes an applicable companion label, W1206 advises on a direct
positional `Bool` constructor literal and W1207 advises on a definite adjacent
run of same-typed positional parameters. Named calls do not emit either
warning, and a purpose-specific sum is the recommended
alternative when a boolean selects behavior. These warnings remain non-fatal.

## Claim Boundary

The implementation and evidence establish parsing, formatting, lowering,
resolution, store persistence, diagnostics, checking, hashing, interpreter and
native behavior, and compatibility for the bounded forms above. They do not
establish that named arguments improve readability for humans. The existing
preregistered readability protocol has no SX.23 cohort; its regression gate is
run only to prove that this change did not disturb the protocol machinery.
