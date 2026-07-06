# Handler gauntlet: OCaml suite → native differential twins

The OCaml handler suites (test/test_handlers.ml, test/test_gauntlet_handlers.ml)
assert on interpreter internals — test-only builtins (bump/note/pick) and OCaml
refs — so they cannot run against a compiled binary. Each semantic case instead
has a standalone .jqd twin here that makes the same guarantee observable on
stdout; test/cli/native-effects.t runs every twin through BOTH engines and
byte-compares stdout, stderr, and exit codes, so the byte comparison IS the
assertion. Counts become printed values via in-language collectors
(emit.collect), per docs/native-plan.md task 71 direction 6.

| OCaml case | twin | printed guarantee |
| --- | --- | --- |
| test_multishot_choose | g01-choose-tuple.jqd | resume twice, both branches collected in order |
| test_multishot_thrice | g02-thrice.jqd | same resumption applied three times |
| test_multishot_deep_inner_effect_exact_count | g03-deep-inner-count.jqd | exact emit count 2: deep handler covers both resumed extents |
| test_state_effect | g04-state-run.jqd | state.run threads get/put; pure body keeps init |
| test_abort_short_circuits | g05-abort-short-circuit.jqd | pending (add 1 _) abandoned |
| test_deep_second_perform | g06-deep-second-perform.jqd | one deep handler covers two sequential performs |
| test_forwarding | g07-forwarding.jqd | non-matching inner handler forwards outward |
| test_nearest_handler_wins | g08-nearest-wins.jqd | inner same-op handler answers |
| test_return_clause_transforms | g09-ret-transforms.jqd | ret wraps a plain completion |
| test_return_clause_runs_per_resumption | g10-ret-per-resumption.jqd | ret doubles EACH branch (cons(2, cons(4, nil))) |
| test_unhandled_names_effect_and_op | g11-unhandled-names.jqd | ungranted/unhandled abort at the root, exit 3 |
| test_unhandled_past_other_handler | g12-unhandled-past-other.jqd | a tick handler does not swallow abort |
| test_clause_body_perform_escapes_outward | g13-clause-escapes-outward.jqd | clause-body perform reaches the OUTER handler |
| test_toplevel_body_effects_isolated | (no twin) | surface-unreachable: the checker refuses effectful decl bodies (E0815) before either engine runs, identically |
| test_op_as_value | g14-op-as-value.jqd | op passed as a value and applied inside a lambda |
| test_resumed_same_op_gives_four_leaves | g15-four-leaves.jqd | two choose points, four leaves in order |
| test_nested_same_op_handler_shadows_outer | g16-nested-shadowing.jqd | inner handler shadows only its region: (1, 2, 1) |
| test_return_clause_is_outside_handled_region | g17-ret-outside-region.jqd | ret body's perform escapes the handler, exit 3 |
| test_abort_skips_pending_argument_evaluation | g18-abort-skips-pending.jqd | empty emit list: the second argument never ran |
| test_escaped_resumption_is_multishot_and_immutable | g19-escaped-resume.jqd | escaped resumption applied twice outside its handle (recursive step type makes the escape typeable) |
| (throw battery, task-71 DoD) | g20-throw-either.jqd | aborting throw clause on both legs |
| (one-shot discipline, task-71 DoD) | g21-conditional-resume.jqd | clause resumes on one path, aborts on the other |
| (enum posterior on m3, task-71 DoD) | g22-enum-m3.jqd | prelude/07-enum multi-shot enumeration, normalized two-coins posterior |
| test_fault_random_deterministic (task-72 DoD) | g23-fault-random.jqd | fault.random's seeded LCG chaos stream, seed in the report |
| test_dst_byte_identical (task-72 DoD) | g24-dst.jqd | clock.fixed + net.scripted + fault.all DST, run-twice stable |
| (chain-order regression, task 72) | g25-chain-order.jqd | capture crossing a state-passer inside a multi-shot resume |
| test_sample_lw_builtin (test_dist_lib.ml, task-72 DoD) | g26-lw-m3.jqd | dist.sample-lw's exact seeded stream on the m3 model |
| (LW isolation, task-72 review round 1) | g27-lw-under-handler.jqd | outer handler survives the driver's search floor |
| (nested drivers, task-72 review round 1) | g28-lw-nested.jqd | inner LW's floor/interception save-restore composes |
| (summation order, task-72 sign-off find) | g29-lw-soft.jqd | soft-likelihood posterior sums in the interpreter's reverse run order |
| (error surface via row erasure, task 76) | e02-erasure-type-error.jqd | smuggled int reaches text.length's type error |
| (error surface via row erasure, task 76) | e03-erasure-arity.jqd | smuggled 1-ary closure reaches the arity rendering |
| (error surface via row erasure, task 76) | e04-erasure-match-failure.jqd | smuggled 5 reaches Match_failure past E0813 |
