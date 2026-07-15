Compiler diagnostics are part of the assertions below. Disable environment-provided color so the
checks behave identically under local opam switches and GitHub Actions.

  $ export OCAML_COLOR=never

External clients can construct arbitrary guarded builtins.

  $ JACQUARD_API="../../src/.jacquard.objs/public_cmi"
  $ cat > api_present.ml <<'EOF'
  > open Jacquard
  > let make (store : Store.t) : Eval.ctx = Eval.make_ctx store
  > let scheduler_bounds = Round_robin.default_bounds
  > EOF
  $ ocamlc -I "$JACQUARD_API" -c api_present.ml
  $ cat > custom_builtin.ml <<'EOF'
  > open Jacquard
  > let _ = Value.VBuiltin ("custom", fun _ -> Ok Value.unit_v)
  > EOF
  $ ocamlc -I "$JACQUARD_API" -c custom_builtin.ml

The trusted payload belongs to a private module. Check the private module directly so this cannot
pass because an attempted `VTrustedBuiltin` payload happened to have some unrelated wrong type.

  $ cat > trusted_builtin.ml <<'EOF'
  > let make = Jacquard.Trusted_builtin.make
  > EOF
  $ if ocamlc -I "$JACQUARD_API" -c trusted_builtin.ml >trusted_builtin.out 2>&1; then
  >   echo "Trusted_builtin.make exposed"
  > elif grep -q "module Jacquard.Trusted_builtin is an alias for module Jacquard__Trusted_builtin, which is missing" trusted_builtin.out; then
  >   echo "Jacquard.Trusted_builtin unavailable"
  > else
  >   cat trusted_builtin.out
  >   exit 1
  > fi
  Jacquard.Trusted_builtin unavailable

Task run identities and the capability that authorizes handle conversion belong entirely to
installed-private modules. Probe each constructor directly: an ordinary type mismatch is not
sufficient evidence because it could leave another forging route public.

  $ for pair in "Concurrency_owner create" "Task_capability runtime" "Task_handle create_run"; do
  >   set -- $pair
  >   module=$1
  >   value=$2
  >   cat > task_private.ml <<EOF
  > let _ = Jacquard.$module.$value
  > EOF
  >   if ocamlc -I "$JACQUARD_API" -c task_private.ml >task_private.out 2>&1; then
  >     echo "Jacquard.$module.$value exposed"
  >   elif grep -Fq "module Jacquard.$module is an alias for module Jacquard__$module, which is missing" task_private.out; then
  >     echo "Jacquard.$module unavailable"
  >   else
  >     cat task_private.out
  >     exit 1
  >   fi
  > done
  Jacquard.Concurrency_owner unavailable
  Jacquard.Task_capability unavailable
  Jacquard.Task_handle unavailable

Unchecked evaluator drivers are absent from the installed interface.

  $ cat > eval_public.ml <<'EOF'
  > open Jacquard
  > let run (ctx : Eval.ctx) expr = Eval.run_expr ctx expr
  > EOF
  $ ocamlc -I "$JACQUARD_API" -c eval_public.ml
  $ for name in step_unchecked run_state_unchecked run_state_capturing_trusted; do
  >   cat > eval_bypass.ml <<EOF
  > open Jacquard
  > let _ = Eval.$name
  > EOF
  >   if ocamlc -I "$JACQUARD_API" -c eval_bypass.ml >eval_bypass.out 2>&1; then
  >     echo "$name exposed"
  >   elif grep -Fq "Error: Unbound value Eval.$name" eval_bypass.out; then
  >     echo "$name sealed"
  >   else
  >     cat eval_bypass.out
  >     exit 1
  >   fi
  > done
  step_unchecked sealed
  run_state_unchecked sealed
  run_state_capturing_trusted sealed

Evaluator context representation and validation caches are unreachable to public clients.

  $ cat > eval_ctx_public.ml <<'EOF'
  > open Jacquard
  > let backing_store (ctx : Eval.ctx) = Eval.store ctx
  > EOF
  $ ocamlc -I "$JACQUARD_API" -c eval_ctx_public.ml
  $ for field in memo evaluator_clean_memo evaluator_mutable_snapshots native_mutable_snapshots recovery_immutable_clean recovery_static_clean; do
  >   cat > eval_ctx_bypass.ml <<EOF
  > open Jacquard
  > let bypass (ctx : Eval.ctx) = ctx.Eval.$field
  > EOF
  >   if ocamlc -I "$JACQUARD_API" -c eval_ctx_bypass.ml >eval_ctx_bypass.out 2>&1; then
  >     echo "$field exposed"
  >   elif grep -Fq "Error: Unbound record field Eval.$field" eval_ctx_bypass.out; then
  >     echo "$field sealed"
  >   else
  >     cat eval_ctx_bypass.out
  >     exit 1
  >   fi
  > done
  memo sealed
  evaluator_clean_memo sealed
  evaluator_mutable_snapshots sealed
  native_mutable_snapshots sealed
  recovery_immutable_clean sealed
  recovery_static_clean sealed

Validated inference states cannot be resumed from arbitrary public frame lists.

  $ cat > resume_public.ml <<'EOF'
  > open Jacquard
  > let resume frames value = Eval.resume_state frames value
  > EOF
  $ ocamlc -I "$JACQUARD_API" -c resume_public.ml
  $ cat > forged_resume.ml <<'EOF'
  > open Jacquard
  > let forge ctx value = Eval.resume_validated_state ctx [] value
  > EOF
  $ if ocamlc -I "$JACQUARD_API" -c forged_resume.ml >forged_resume.out 2>&1; then
  >   echo forgeable
  > elif grep -Fq "Error: This expression has type 'a list" forged_resume.out \
  >   && grep -Fq "but an expression was expected of type" forged_resume.out \
  >   && grep -Fq "Jacquard.Eval.validated_captured_kont" forged_resume.out; then
  >   echo sealed
  > else
  >   cat forged_resume.out
  >   exit 1
  > fi
  sealed

Ordinary mode-aware captures likewise cannot be forged from or unwrapped into public frame lists.

  $ cat > forged_captured_resume.ml <<'EOF'
  > open Jacquard
  > let forge ctx value = Eval.resume_captured_state ctx [] value
  > EOF
  $ if ocamlc -I "$JACQUARD_API" -c forged_captured_resume.ml >forged_captured_resume.out 2>&1; then
  >   echo forgeable
  > elif grep -Fq "Error: This expression has type 'a list" forged_captured_resume.out \
  >   && grep -Fq "but an expression was expected of type" forged_captured_resume.out \
  >   && grep -Fq "Jacquard.Eval.captured_kont" forged_captured_resume.out; then
  >   echo sealed
  > else
  >   cat forged_captured_resume.out
  >   exit 1
  > fi
  sealed
  $ cat > unwrap_captured_resume.ml <<'EOF'
  > open Jacquard
  > let unwrap (kont : Eval.captured_kont) =
  >   match kont with Eval.Multi_kont frames -> frames
  > EOF
  $ if ocamlc -I "$JACQUARD_API" -c unwrap_captured_resume.ml >unwrap_captured_resume.out 2>&1; then
  >   echo unwrap-able
  > elif grep -Fq "Error: Unbound constructor Eval.Multi_kont" unwrap_captured_resume.out; then
  >   echo sealed
  > else
  >   cat unwrap_captured_resume.out
  >   exit 1
  > fi
  sealed

Once-resumption consumption and captured frames belong to a private module. The evaluator seals a
real capture before returning it; clients cannot construct a token, inspect it, restore it, or
extract frames and rewrap the same capture with a fresh budget.

  $ cat > once_state_public.ml <<'EOF'
  > open Jacquard
  > let _ = Once_state.snapshot
  > EOF
  $ if ocamlc -I "$JACQUARD_API" -c once_state_public.ml >once_state_public.out 2>&1; then
  >   echo "Once_state exposed"
  > elif grep -Fq "module Once_state is an alias for module Jacquard__Once_state, which is missing" once_state_public.out; then
  >   echo "Once_state unavailable"
  > else
  >   cat once_state_public.out
  >   exit 1
  > fi
  Once_state unavailable
  $ cat > once_factory.ml <<'EOF'
  > open Jacquard
  > let _ = Value.once_resume
  > EOF
  $ if ocamlc -I "$JACQUARD_API" -c once_factory.ml >once_factory.out 2>&1; then
  >   echo "once factory exposed"
  > elif grep -Fq "Error: Unbound value Value.once_resume" once_factory.out; then
  >   echo "factory sealed"
  > else
  >   cat once_factory.out
  >   exit 1
  > fi
  factory sealed
  $ cat > once_forge.ml <<'EOF'
  > open Jacquard
  > let forge (frames : Value.kont) = Value.VOnceResume frames
  > EOF
  $ if ocamlc -I "$JACQUARD_API" -c once_forge.ml >once_forge.out 2>&1; then
  >   echo forgeable
  > elif grep -Fq "Jacquard.Value.kont Jacquard.Once_state.t" once_forge.out \
  >   && grep -Fq "Jacquard.Once_state.t is abstract because" once_forge.out; then
  >   echo sealed
  > else
  >   cat once_forge.out
  >   exit 1
  > fi
  sealed

Raw recovery helpers and marker walkers are absent; recovery is available only through an
isolated abstract session.

  $ cat > recovery_public.ml <<'EOF'
  > open Jacquard
  > let start (ctx : Check.ctx) = Check.start_recovery ctx
  > let check identity session top = Check.check_recovery_top ~identity session top
  > EOF
  $ ocamlc -I "$JACQUARD_API" -c recovery_public.ml
  $ for path in Check.check_top_with Check.Recovery Recovery_marker.expr; do
  >   cat > check_bypass.ml <<EOF
  > open Jacquard
  > let _ = $path
  > EOF
  >   if ocamlc -I "$JACQUARD_API" -c check_bypass.ml >check_bypass.out 2>&1; then
  >     echo "$path exposed"
  >   elif [ "$path" = Check.check_top_with ] \
  >     && grep -Fq "Error: Unbound value Check.check_top_with" check_bypass.out; then
  >     echo "$path sealed"
  >   elif [ "$path" = Check.Recovery ] \
  >     && grep -Fq "Error: Unbound constructor Check.Recovery" check_bypass.out; then
  >     echo "$path sealed"
  >   elif [ "$path" = Recovery_marker.expr ] \
  >     && grep -Fq "Error: The module Recovery_marker is an alias for module Jacquard__Recovery_marker, which is missing" check_bypass.out; then
  >     echo "$path sealed"
  >   else
  >     cat check_bypass.out
  >     exit 1
  >   fi
  > done
  Check.check_top_with sealed
  Check.Recovery sealed
  Recovery_marker.expr sealed

Checker inference stacks and mutable scheme caches are also abstract.

  $ cat > check_ctx_public.ml <<'EOF'
  > open Jacquard
  > let backing_store (ctx : Check.ctx) = Check.store ctx
  > EOF
  $ ocamlc -I "$JACQUARD_API" -c check_ctx_public.ml
  $ for field in builtin_sigs term_sigs level checking sites origins tier_apps tier_ops; do
  >   cat > check_ctx_bypass.ml <<EOF
  > open Jacquard
  > let bypass (ctx : Check.ctx) = ctx.Check.$field
  > EOF
  >   if ocamlc -I "$JACQUARD_API" -c check_ctx_bypass.ml >check_ctx_bypass.out 2>&1; then
  >     echo "$field exposed"
  >   elif grep -Fq "Error: Unbound record field Check.$field" check_ctx_bypass.out; then
  >     echo "$field sealed"
  >   else
  >     cat check_ctx_bypass.out
  >     exit 1
  >   fi
  > done
  builtin_sigs sealed
  term_sigs sealed
  level sealed
  checking sealed
  sites sealed
  origins sealed
  tier_apps sealed
  tier_ops sealed
