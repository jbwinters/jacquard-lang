# Explicit dictionary decision

Status: ratified successor contract for Jacquard 0.1.

## Decision

Jacquard uses explicit dictionaries for ad-hoc polymorphism. A dictionary is an
ordinary value of an ordinary declared type. Generic functions receive that
value as an argument, so a reader can see which implementation a call uses.

The ring-0 prelude provides `Eq`, `Ord`, `Show`, and `Num`. Their constructors
use labeled fields, while their accessors are ordinary handwritten terms. The
numeric shape is:

```jacquard
type Num a =
  | MkNum(
      add-fn: (a, a) ->{} a,
      sub-fn: (a, a) ->{} a,
      mul-fn: (a, a) ->{} a,
      div-fn: (a, a) ->{} a,
    )
```

`num.add`, `num.sub`, `num.mul`, and `num.div` return the corresponding method.
`int.num` and `real.num` are the canonical instances. Generic code chooses an
instance explicitly:

```jacquard
add-with(dictionary, left, right) =
  num.add(dictionary)(left, right)

add-with(int.num, 40, 2)
```

An alternate instance is just another `MkNum` value and is selected only when
the caller passes it. There is no hidden search and therefore no
missing-instance or ambiguous-instance diagnostic.

## Effects and evaluation

The four standard `Num` methods are pure. A user-defined dictionary may put an
effect in a method field type, and that effect remains visible in callers. For
example, a field of type `(a, a) ->{Console} a` makes a generic call carry
`Console`.

Constructing a dictionary, selecting a method, and calling it follow the
existing strict left-to-right evaluation order. No evaluator convention was
added. Dictionary identity, storage, lookup, quotation, and separate
compilation use the existing `DefType` and `DefTerm` rules.

## Compatibility and identity

The long-standing bare integer builtins remain available. New dotted integer
names use byte-identical builtin marker bodies, so each dotted name resolves to
the already published member hash:

| old name | dotted name | shared HASH_V0 |
|---|---|---|
| `add` | `int.add` | `2c16b4f49e8261504cba9692cb27bbd26e767dd293785379041e95e1e0e61c4d` |
| `sub` | `int.sub` | `e487565dcfd7ca43e957eaf644fa0691e9aa10bb2cd717b9ca53a0688b522174` |
| `mul` | `int.mul` | `dc4f095e4e9e508c3644c04972a8e7a696e1875bb5206297a58997df46850a52` |
| `div` | `int.div` | `e92672943a1fb61cf8154d5a22e4a410c72db2027232884e3c1b0d37df1d7d1f` |

Existing `Eq`, `Ord`, `Show`, bare integer, and dotted real definitions keep
their identities and behavior. Historical release manifests are not changed.

If Jacquard later gains accepted convenience syntax, it must elaborate to
these same visible dictionary values and arguments. Existing 0.1 code must not
change meaning or instance choice.

## Alternatives considered

- Rust-style global traits were rejected for 0.1. Global lookup, coherence,
  overlap, and orphan rules would make instance choice less local and require
  new language and package decisions.
- Abilities-like overloading was rejected for this purpose. It would hide
  ordinary numeric behavior behind nonlocal resolution and blur the boundary
  between value-level choices and Jacquard effect rows.
- Modular-implicit-style scoped elaboration remains a possible research
  direction. It is not part of 0.1 and would have to elaborate to this exact
  value-passing contract.

Local explainability and visible instance choice take priority over terseness.

## Deliberate exclusions

This decision adds no implicit resolution, global instance registry,
overlap/orphan/coherence rule, operator or precedence syntax, numeric
defaulting, custom operator, macro, generated field accessor, record system,
kernel form, evaluator rule, native calling convention, or performance claim.
It also adds no numeric identity, negation, remainder, comparison, conversion,
or superclass method to `Num`; those would be separate product decisions.
