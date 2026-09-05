# Checked effect payload containment

This is the implementation contract for the successor soundness repair.
Historical manifests and recorded source evidence retain their original bytes.

The checked program below must be refused before interpreter execution or native
compilation. At the predecessor commit it checks successfully and returns
`("hi", "hi")` despite its declared `(Text, Int)` result.

```text
bad : () ->{} (Text, Int)
bad() = state.run(fn () -> { put("hi"); get() }, 0)
bad()
```

The repair retains payload constraints inside checker effect rows. Operations
and handler clauses in one handled region share these constraints. Arrow
unification, row inclusion, branch joins, generalization, instantiation, and
checker recovery must preserve them. Aliasing an operation or handler, passing
it through a higher-order function, or adding a source annotation cannot erase
the relationship between a performed payload and its handler. A nested complete
handler establishes an independent payload constraint; independent calls may
use different types.

State's `get` result, `put` argument, initial state, and final state must agree.
Throw's payload must agree with its catch callback or returned error. Emit's
payload must agree with its collection element or pipe callback. Abortive
operation results remain independently polymorphic; the repair must not require
all uses of `throw` to have one return type.

The implementation must distinguish scoped payload parameters from operation
polymorphism. A handler for an operation-polymorphic parameter must work for
every instantiation, and that parameter must not escape into the handler answer
or surrounding environment. The existing trusted Async and Channel contracts
retain their typed handle relationships and independent operation instances.
Dynamic Eval still checks its quoted expression without tying the resulting value
to the outer expected type; that unchecked result remains a separate boundary.

The permanent kernel, source carrier, operation identities, and `HASH_V0` bytes
remain unchanged. This containment does not introduce source-level effect
instances or ratify the successor scoped-instance design. Where the existing
carrier cannot retain a payload relationship, static refusal is permitted and
must be documented with an actionable diagnostic. In particular, a nominal
callback field must not hide a payload parameter that its declared type cannot
represent. Generic type parameters that carry the complete inferred callback
type continue to retain its constraints.

A handler for an effect with shared payload parameters must cover every declared
operation. A partial State handler, for example, could intercept `get` while an
omitted `put` reaches an outer state region. The current effect rows cannot retain
that per-operation forwarding relationship, so these partial handlers are refused
even when a particular body uses only the covered operation. Complete nested
handlers still establish independent regions. This restriction does not apply to
effects without shared payload parameters.

Acceptance requires the normal checker and CLI regressions for State, Throw,
Emit, aliases, higher-order transport, annotations, nested handlers, and nominal
callback storage; positive same-type and independent-instantiation cases;
interpreter/native agreement where supported; the complete applicable Core
gates; and a fresh independent review of the final commit. Passing a runtime
guard alone is not static rejection.

Migration from the predecessor checker:

- Keep each State region at one state type, including `get`, `put`, initial state,
  and final state. Use independent or nested complete handlers for different types.
  A custom State handler needs both `get` and `put` clauses. Define the intended
  behavior of each operation explicitly; forwarding a clause's operation outward
  retains the outer region's payload constraint.
- Convert errors to one declared error type before throwing them through one
  handler, and keep an Emit region homogeneous. A sum type can represent deliberate
  alternatives.
- Replace a nominal fixed callback field such as
  `type Writer = Writer(write: (Text) ->{State} ())` with
  `type Writer f = Writer f`. The complete callback type then remains an argument
  of `Writer`, including its inferred payload constraints. This refusal also covers
  callbacks nested inside containers and open callback rows. All nominal field
  variables must occur in the type declaration's header; quantified fields are refused
  because this checker has no representation for a separately polymorphic field.
- Keep operation-polymorphic values inside their handler clause. A result-only
  parameter cannot be specialized to a concrete result by a user-defined handler.

A stored definition group is checked by its actual recursive components. Completed
independent helpers generalize before their callers are checked; mutually recursive
members stay monomorphic during inference. This is necessary for the prelude's
polymorphic distribution-enumeration helper, and changes neither group storage nor
canonical identities.

The native error fixtures that previously exploited row erasure now assert equal
static refusals through `run` and `build`. A test-only runtime probe first verifies
that refusal, then deliberately bypasses checking to retain defensive interpreter,
native, and sanitizer coverage. No unchecked option is added to the public CLI.

The stored-component correction also retains callback effect rows for
`governance.approval.before-action`, `mnode.update`, `test.replay`, and
`test.replay-loose`. Their bodies already propagate those effects. Two declaration
classifications and ten function-call classifications move from pure to
row-polymorphic, while the prelude's 383 declarations, 1,480 calls, and 53 handler
clauses retain their identities and source structure. Throw coupling narrows the
preflight `scripted` result to `Text` and the governed-workspace outer errors to
`Text`, matching their existing runtime values.
