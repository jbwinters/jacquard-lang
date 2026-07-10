# Jacquard canonical serialization, format V0

Companion to `jacquard-kernel-ast-m0.md` §6 and `src/canon.ml` (plan W1.5). This byte format
exists only as a hash input; it is never parsed back. Any change to it changes every hash and
must bump the format name.

## Primitives

- **tag** — one byte identifying a constructor (values below).
- **varint** — unsigned LEB128: little-endian base-128, high bit = continuation. Used for
  lengths, arities, de Bruijn indices, ordinals.
- **int64** — 8 bytes big-endian two's complement. OCaml native ints are 63-bit (decision
  D2); they widen to 64-bit here.
- **real** — 8 bytes big-endian IEEE-754 bits, normalized first: every NaN becomes the quiet
  NaN `0x7ff8000000000000`; `-0.0` becomes `+0.0`. This keeps hash identity aligned with
  `Form.equal_ignoring_meta`, which treats all NaNs equal and `-0.0 = +0.0`.
- **text** — varint byte length + UTF-8 bytes (no normalization, decision D3).
- **hash** — the raw 32 digest bytes of `HASH_V0` (SHA-256, decision D1), no length prefix.

## Meta and names

Meta is never serialized (the metadata law, spec §3). Local variable names are never
serialized: binders push their variables left-to-right, and an occurrence serializes as its
de Bruijn distance (varint; 0 = most recently bound). Pattern binders (`pvar`, `pas`)
serialize as bare tags — position is identity. `defterm` binding names are erased (term
renames are free). Type/effect declarations are nominal in M0: the type name, constructor
names, field labels, and operation names are content and do hash.

Type and row variables bound by `tforall` are de Bruijn-indexed the same way (subtag `0x01` +
varint); free ones serialize by name (subtag `0x00` + text).

## Tags

Expressions:

| tag | form | payload |
|-----|------|---------|
| 0x01 | lit | lit subtag: 0x01 int64, 0x02 real, 0x03 text |
| 0x02 | var | varint de Bruijn index |
| 0x03 | ref | refkind (0x01 term, 0x02 con, 0x03 op) + hash |
| 0x04 | lam | varint arity + pats + body |
| 0x05 | app | fn + varint argc + args |
| 0x06 | let | 0x00 nonrec / 0x01 rec + pat + value + body |
| 0x07 | match | scrutinee + varint clausec + (pat + body)* |
| 0x08 | tuple | varint n + items |
| 0x09 | handle | body + ret pat + ret body + varint opc + (op hash + varint paramc + pats + body)* |
| 0x0A | quote | quoted payload (below) |
| 0x0B | unquote | expr |
| 0x0C | ann | expr + type |
| 0x0D | groupref | varint canonical group index (absent in ordering signatures) |

Patterns: 0x20 pwild, 0x21 pvar (bare), 0x22 plit (+ lit), 0x23 pcon (+ hash + varint n +
pats), 0x24 ptuple (+ varint n + pats), 0x25 pas (+ inner; binder name erased).

Types: 0x30 tref (+ hash), 0x31 tvar (+ bound/free subtag), 0x32 tapp (+ head + varint n +
args), 0x33 tarrow (+ varint n + params + row + result), 0x34 ttuple, 0x35 tforall (+ varint
tyvarc + varint rowvarc + body), 0x37 self-reference (a `tref` naming the enclosing
`deftype`/`defeffect` itself — a recursive declaration cannot contain its own hash, so the
self-reference is positional, like `groupref` for terms). Rows: 0x36 + varint n + effect
hashes **sorted bytewise** (effect sets are unordered) + 0x00 closed / 0x01 + var.

Quoted payloads (raw triples, meta erased): 0x50 form (+ head text + varint argc + args),
where scalar args tag 0x52 int64, 0x53 real, 0x54 text, 0x55 sym, 0x56 hash — except an
`(unquote e)` form, which serializes as 0x51 + the splice as an *expression* under the
ambient de Bruijn environment (splices evaluate, so their locals must stay alpha-invariant).

### Reserved surface-reference markers

The pre-resolution/quote compatibility marker from the kernel spec has no canonical tag of its
own. `(surface-ref-v0 con name)` and `(surface-ref-v0 op name)` inside quoted data serialize as
ordinary quoted `Form.t` values under `0x50`: the head is the text `surface-ref-v0`, and the kind
and name are ordinary `0x55` symbol arguments. Consequently `con` and `op` are structurally and
bytewise distinct quoted data even after all metadata is erased.

The `surface-ref-v0` head is reserved, so malformed occurrences are rejected by kernel validation
before resolution or hashing. Canonicalization defensively applies the same validation at every
quote depth if a programmatically constructed typed tree bypasses the normal validator. Invalid
arity is `E0202`, non-symbol arguments are `E0203`, and a kind other than `con` or `op` is `E0210`;
no hash is produced for any of those cases.

This reservation does **not** change the V0 byte format or `HASH_V0`: it assigns meaning and
validation to an ordinary `0x50` form encoding that the format already supports. No tag was added,
the format/version remains V0, and every previously valid tree serializes to exactly its previous
bytes. Existing hashes therefore do not drift; newly accepted valid markers simply occupy bytes
that were already representable as quoted forms.

Declarations: 0x40 defterm (+ varint n + members in canonical order; member = 0x43 +
annotation option (0x00/0x01+type) + value), 0x41 deftype (+ name + varint tyvarc + varint
conc + conspecs; conspec = 0x44 + name + varint fieldc + fields; field = 0x45 + label option
+ type), 0x42 defeffect (+ name + varint tyvarc + varint opc + opspecs; opspec = 0x46 + name
+ varint paramc + param types + result type).

## Hash derivations (domain-separated)

| value | input to HASH_V0 |
|-------|------------------|
| expression hash | `"E"` + expr bytes |
| deftype / defeffect hash | `"D"` + decl bytes |
| defterm group hash | `"G"` + 0x40 + varint n + members in canonical order |
| defterm member hash | `"M"` + group hash bytes + varint canonical index |
| constructor hash | `"C"` + decl hash bytes + varint ordinal |
| operation hash | `"O"` + decl hash bytes + varint ordinal |

## Canonical group order

A `defterm` group is ordered independently of source order:

1. Serialize each member with every `groupref` index **erased** (tag only) — the round-0
   signature.
2. While signatures tie and fewer than n rounds have run: assign each member the rank of its
   signature among the sorted distinct signatures, re-serialize with `groupref i` replaced by
   the referenced member's rank, and repeat.
3. Sort members by final rank. Refinement propagates only out-references, so members with
   identical bodies can stay tied even when *other* members reference them asymmetrically —
   a source-based tie-break would leak source order into the hash. The remaining tie classes
   are therefore resolved exhaustively: among every ordering that permutes members only
   within their tie class, keep the one whose full group serialization (with substituted
   canonical indices) is lexicographically least. The choice depends only on bytes.
4. Candidates with byte-identical serializations are genuinely automorphic; among them the
   members' binding names choose the index assignment. Names are erased from the bytes, so
   this stabilizes only which twin gets which member index, never the group hash. (Renaming
   one of two byte-identical twins may swap their member hashes; the group hash is
   unchanged.)
5. Tie classes requiring more than 5040 candidate orderings are rejected (E0505).

Group members then serialize with `groupref` carrying the *canonical* index, and the plan's
invariant holds: permuting source order never changes the group hash.
