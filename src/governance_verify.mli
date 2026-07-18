(** Cross-artifact verification for governed effect membranes.

    The input is a versioned analysis IR derived by trusted tooling from resolved, typechecked
    Jacquard artifacts. It is not a serialized policy format and is never accepted as an authority
    grant. The verifier checks the relationships that ordinary row typing cannot express and returns
    stable E1400--E1412 diagnostics before any governed computation runs. *)

type authority =
  | Effect of Hash.t
  | Resource of { effect_id : Hash.t; scope : string; configuration : Hash.t }

type identity_claim = { carried : Hash.t; canonical_subject : Form.t; meta : Meta.t }
(** A carried HASH_V0 identity and the exact canonical Code subject from which it must be
    recomputed. Metadata supplies diagnostics only. *)

type term_ref = { hash : Hash.t; label : string; meta : Meta.t }
(** A resolved term whose actual inferred scheme is read from the store. *)

type proposal_binding = {
  identity : identity_claim;
  call_id : Hash.t option;
  policy_id : Hash.t option;
  assessment_id : Hash.t option;
  authority : authority list option;
  serialized : Form.t list;
  meta : Meta.t;
}
(** Static evidence that every Ask proposal binds all exact review inputs. *)

type action_atom =
  | Raw of { effect_id : Hash.t; resources : authority list }
  | Forward of Hash.t
      (** A statically resolved leaf effect or facade-operation call. [Forward] recursively expands
          the referenced operation's action until raw effects are reached; cycles and dynamic or
          unknown operation selection fail closed. *)

type flow_kind = Live_execute | Live_refuse | Dry_simulated | Dry_refuse
type flow_step = Invoke_action | Record_completion | Consume_resume

type flow = { kind : flow_kind; gate : Hash.t; steps : flow_step list; meta : Meta.t }
(** One disposition branch after invoking its exact canonical gate. Gate-owned
    Evaluated/Consented/simulation events are covered by the pinned gate identity; [steps] describes
    facade-owned work after the gate returns. *)

type lineage =
  | Original
  | Unchanged_forward of { previous_call_id : Hash.t; current_call_id : Hash.t }
  | Transformed_forward of {
      previous_call_id : Hash.t;
      current_call_id : Hash.t;
      parent_call_id : Hash.t option;
    }

type operation = {
  operation_id : Hash.t;
  frozen_authority : authority list;
  call_authority : authority list;
  proposal_authority : authority list;
  call : identity_claim;
  bound_policy : identity_claim;
  assessment : identity_claim;
  proposal : proposal_binding;
  serialized_call_data : Form.t list;
  normalizer : term_ref;
  summarizer : term_ref;
  action : action_atom list;
  live_flows : flow list option;
  dry_flows : flow list option;
  lineage : lineage;
  meta : Meta.t;
}

type sequence_contract = {
  owner_count : int;
  nested_owner_count : int;
  owner_token : int;
  layer_tokens : int list;
  meta : Meta.t;
}
(** Lexical provenance for the single [with-sequence] owner and the exact token binder threaded to
    every layer. Integers are analysis-local binder IDs, not runtime sequence values. *)

type contract = {
  version : string;
  facade_effect : Hash.t;
  operations : operation list;
  governed_reachable_effects : Hash.t list;
  sequence : sequence_contract;
  meta : Meta.t;
}

type operation_report = {
  operation_id : Hash.t;
  authority : authority list;
  call_id : Hash.t;
  proposal_id : Hash.t;
}

type report = { version : string; facade_effect : Hash.t; operations : operation_report list }

val version : string
(** Exact verifier IR version accepted by {!verify}. *)

val code_hash : Form.t -> Hash.t
(** [code_hash subject] is the canonical Code HASH_V0 boundary used by [code.hash]: compact
    metadata-free form bytes hashed with HASH_V0. *)

val verify : Store.t -> contract -> (report, Diag.t list) result
(** [verify store contract] checks the complete membrane contract without evaluating it or mutating
    [store]. It rejects mutable-name aliases for canonical effects and frozen governance
    terms/types, checks every arrow nested in the real inferred schemes of referenced terms, and
    requires the exact normalizer/summarizer result shapes. It accumulates deterministic
    E1400--E1412 diagnostics with source spans. Missing verifier vocabulary, malformed evidence,
    lookup/type errors, or any violated invariant return [Error]. *)

val diagnostic_codes : (string * string) list
(** Stable governance-verifier diagnostic catalog. *)
