(** Runtime values, environments, and continuation frames (plan W2.1/W2.2).

    Frames are data, not host closures: W2.4 slices the continuation to build multi-shot
    resumptions, so everything a suspended computation needs must be inspectable and reusable. The
    only host functions live inside [VBuiltin] and the sealed [VTrustedBuiltin] payload.

    Environments are persistent string maps to mutable cells; only [let rec] ever mutates a cell (to
    tie the recursive knot, plan W2.2). A closure captures its whole {!scope} — environment plus the
    enclosing [defterm] group's member hashes, so [GroupRef] works inside closure bodies. *)

module Env = Map.Make (String)

type t =
  | VInt of int
  | VReal of float
  | VText of string
  | VHash of Hash.t  (** an opaque, validated HASH_V0 digest; constructed only by trusted natives *)
  | VTuple of t list
  | VCon of { con : Hash.t; name : string; args : t list }
      (** a saturated constructor application; identity is the derived constructor hash (equal to
          [Canon.con_hash type_decl_hash ordinal]), [name] is display-only *)
  | VConstructor of { con : Hash.t; name : string; arity : int }
      (** an unapplied constructor of nonzero arity; [App] saturates it exactly (uncurried, decision
          D5) *)
  | VOp of { op : Hash.t; name : string; effect_ : string }
      (** an effect operation as a first-class value; applying it performs (spec §5.1: no [Perform]
          form — invoking an op is plain [App]) *)
  | VClosure of { scope : scope; params : Kernel.pat list; body : Kernel.expr }
  | VBuiltin of string * (t list -> (t, Runtime_err.t) result)
      (** an unreviewed host callback; application guards the complete invocation graph *)
  | VTrustedBuiltin of t Trusted_builtin.t
      (** a reviewed internal prelude callback. Its payload type belongs to a Dune-private module,
          so external library clients cannot attach callbacks to this constructor. *)
  | VCode of Form.t  (** a quoted triple; payload is pre-resolution data (spec §5.1) *)
  | VResume of frame list
      (** a resumption: the sliced continuation as immutable data — invoking it twice just reuses
          the list (multi-shot for free, plan W2.4) *)
  | VOnceResume of kont Once_state.t
      (** an affine resumption. Aliases share opaque consumption state, so the dynamic at-most-once
          check belongs to the captured instance rather than to a particular variable holding it. *)

and env = t ref Env.t

and scope = { env : env; group : Hash.t array }
(** evaluation scope: lexical environment plus the enclosing defterm group's member hashes (source
    order), for [GroupRef] *)

and frame =
  | FAppFn of { args : Kernel.expr list; scope : scope }
      (** function position evaluated; arguments pending *)
  | FAppArgs of { fn : t; done_rev : t list; pending : Kernel.expr list; scope : scope }
  | FLet of { binder : Kernel.pat; body : Kernel.expr; scope : scope }
  | FMatch of { scrutinee_meta : Meta.t; clauses : Kernel.clause list; scope : scope }
  | FTuple of { done_rev : t list; pending : Kernel.expr list; scope : scope }
  | FQuote of { payload : Form.t; done_rev : t list; pending : Kernel.expr list; scope : scope }
      (** collecting live-splice values for a quote payload (W2.5) *)
  | FHandle of handler  (** an installed deep handler (W2.4) *)

and handler = {
  hret : Kernel.pat * Kernel.expr;
  hops : (Hash.t * Kernel.opclause) list;  (** op hash -> clause *)
  hscope : scope;
}

and kont = frame list

let empty_scope = { env = Env.empty; group = [||] }
let unit_v = VTuple []

(** Stable rendering for goldens and diagnostics. Reals use the reader-compatible spelling; text is
    escaped like source; constructors print as [Name] or [Name(arg, ...)]; non-literal values print
    as bracketed placeholders. *)
let rec show = function
  | VInt i -> string_of_int i
  | VReal r -> Printer.real_repr r
  | VText s -> "\"" ^ Printer.escape_text s ^ "\""
  | VHash hash -> "#" ^ Hash.to_hex hash
  | VTuple items -> "(" ^ String.concat ", " (List.map show items) ^ ")"
  | VCon { name; args = []; _ } -> name
  | VCon { name; args; _ } -> name ^ "(" ^ String.concat ", " (List.map show args) ^ ")"
  | VConstructor { name; arity; _ } -> Printf.sprintf "<constructor %s/%d>" name arity
  | VOp { effect_; name; _ } -> Printf.sprintf "<op %s.%s>" effect_ name
  | VClosure _ -> "<closure>"
  | VBuiltin (name, _) -> Printf.sprintf "<builtin %s>" name
  | VTrustedBuiltin builtin -> Printf.sprintf "<builtin %s>" (Trusted_builtin.name builtin)
  | VCode payload -> "(quote " ^ Printer.inline_form payload ^ ")"
  | VResume _ | VOnceResume _ -> "<resume>"

let pp fmt v = Format.pp_print_string fmt (show v)
