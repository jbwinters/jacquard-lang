# Reviewing Effect Authority and Uncertainty

Status: ET.8 tooling guide. The normative metadata is
[`effect-taxonomy.md`](effect-taxonomy.md) and
[`../spec/effect-taxonomy-v1.tsv`](../spec/effect-taxonomy-v1.tsv).

Jacquard review is identity-first. A short name helps a person read a row, but
only the resolved `DefEffect` hash selects blessed metadata. A user effect that
spells itself `net` is not official `Net`; a name-only match is never enough,
including for a reserved taxonomy name.

## Released identity ledger

These are the exact seventeen implemented blessed identities. Review tooling must
not approve an abbreviation or a name-only match.

| effect | exact `HASH_V0` interface identity |
|---|---|
| `Abort` | `bfdfaeee39c6f5290ebea28e805bdeb92f448f1a1e0b9c47f3c70c53975b4375` |
| `Throw` | `f236e77750a9c066fdff9220b81ab1ba6b6a5dd5226ab63dfd112f4b14aa504e` |
| `State` | `44a2946788e38fb6a734449880cce3d499aa5e2f876c5d9119773533b3d621a9` |
| `Emit` | `28afafc8cbec5108fa6103e4670269080373bc0d9a07b1f0f257861ef4b948f6` |
| `Dist` | `5a31778adb668e471820541428a4d809f40206b231b2f9d40aeb36d5684415f0` |
| `Fault` | `0b7297f7a38573108de121c794c6be6471d9c43bd4749d435a3cd247e7d5f008` |
| `Eval` | `94f82f3c17d019d6ca5092b24f19d51ad40720d0accbc4c50641ade0ca056c24` |
| `Console` | `73e8a208eb7fadc43e3bd7aef1474884cf99ce86f8108ddf0e3baff0a74b3fc9` |
| `Clock` | `9041c22386c41541b6b6818bcb26f1aeb02ae8f0dce3fedbf5f411e4bff9eecb` |
| `Fs` | `8ec13169c7181851364e55353232af8e3c7f5ee4a010fa3067fcf2058dd5ed84` |
| `Net` | `be1aad7345c6215f227e63df6c7d05874a464f207599d4f5b85de8b0a6675b45` |
| `Workspace` | `d5831f495fdb26e05d53d886786f07230f7bb808ac4933ab32e0a9238c89f9d0` |
| `Infer` | `324b8f59279db3cabbfaaba430168717057cea8fc1435a11a1a9106e3e6fb4d8` |
| `Approval` | `362425a29077a7efbcc37047182e579f46199a50473045eb4126a917dfc2a196` |
| `Audit` | `40bc4343fb2b4bcc18b18f63f7bb68675b746751bb40b876072e622046a81372` |
| `Secret` | `6d092eccc3c9858a2a95120da5a011964cbb3ad76968e11c1cbb062c119fbb31` |
| `Judge` | `9b677b5e2c3ec8521c5d5dfac321ae361a959565e1cbf082fec4512199977354` |
| `Channel` | `bf9a334188ac13495eeb070fdc215d51763d9761b4775c98c61f44ebb1b03756` |

One schema-reserved name also has a published identity:

| effect | exact `HASH_V0` interface identity | shipped boundary |
|---|---|---|
| `Async` | `4ff8ce05ab09968163492b3be40fc91381b47dee5fb4b2980f9416d50f38e66f` | interpreted structured scheduler from SC.9 |

The seven remaining blessed names are **reserved/unimplemented**: `Choose`,
`Env`, `Pg`, `Blob`, `Serve`, `Crypto`, and `Log`. They have schemas
and a `first-release` compatibility policy, but no shipped interface hash,
handler, grant, or availability promise.

## Review workflow

1. Run `jacquard check PROGRAM --print-sigs`; inspect every inferred row.
2. Run `jacquard check PROGRAM --manifest GRANTS`; a mismatch refuses without
   executing the program.
3. Run `jacquard diff REVIEWED PROPOSED`; typed effect-row changes render as
   authority changes keyed by resolved identity.
4. Confirm how every remaining effect is handled or installed. The canonical
   inventory is in the taxonomy; an unfamiliar user handler requires its own
   review.
5. Review uncertainty separately from authority. `Dist` risk `none` means no
   external authority, not certainty. `Infer` output, posterior weights, and
   governance confidence remain evidence rather than verified facts or consent.

## Exact manifest evidence

For official Net, the manifest refusal uses identity-confirmed metadata:

```text
error[E0814]: this program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `net.get`)
  hint: grant it with --allow net, or handle the effect in the program
```

A colliding user effect stays fully identified and unrated:

```text
error[E0814]: this program requires unpackaged:a46cb801752d/net [unrated user effect #a46cb801752d15e51f6c46c91d0c4fa874b337d7186f8b3003230442baad74f1], which is not granted (performed via `package.fetch`)
  hint: handle the effect in the program (unregistered user effects have no built-in --allow grant)
```

These exact outputs are executed by `test/cli/manifest.t`.

## Exact authority-diff evidence

A blessed change receives reviewed risk and meaning:

```text
- authority {Fs [world/medium] — read or mutate the filesystem under the granted root handler}
+ authority {Net [world/high] — reach a network endpoint through the granted handler}
```

Two versions of one user effect remain distinct, full, and unrated:

```text
- authority {unpackaged:f32431aafb35/custom [unrated user effect #f32431aafb35ef647194bd1f8ee2fee3278f49e61fc218c72daba69a81f72e26]}
+ authority {unpackaged:e5a04705ef6a/custom [unrated user effect #e5a04705ef6a4df51a0d4529d738941a3e428e4cf4341b95e65fbd030da88cec]}
```

`test/cli/diff.t` executes both forms. Quoted type-shaped data does not receive
an authority label; only the resolved row position of a typed arrow does.

## Limits reviewers must retain

- Risk metadata never grants authority and is not a vulnerability score or
  policy verdict.
- Root `Fs` and `Net` grants are effect-wide, not path/domain object
  capabilities. This runtime is not a production sandbox.
- Secret opacity is not taint tracking. `secret.expose` returns ordinary `Text`,
  which may then be copied or leaked.
- Approval requires an exact hash-bound Decision. Model output, a posterior, or
  `Assessment.confidence` cannot fabricate consent.
- The release implements finite discrete uncertainty only; it does not provide
  continuous distributions or verified model truth.
- A reserved schema alone is compatibility vocabulary, not an implementation or
  roadmap commitment. Async is interpreted scheduler infrastructure; Channel is
  a released exact-identity interpreted facility and has no native runtime.
