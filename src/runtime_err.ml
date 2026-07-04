(** Runtime errors (plan W2.2): what a well-formed, resolved program can still do wrong at run time.
    The checker (M2) will rule most of these out statically; the interpreter must trap them all the
    same. *)

type t =
  | Match_failure of string
      (** no clause matched; carries the printed scrutinee (plan W2.2 done-when) *)
  | Unhandled of { effect_ : string; op : string }
      (** an operation reached the root with no handler and no grant — the capability story at
          runtime (spec §5.1 rule 7) *)
  | Arity of string  (** wrong number of arguments in an uncurried application *)
  | Type_error of string  (** applying a non-function, spliced non-code, and similar *)
  | Unresolved of string  (** an unresolved name or dangling hash reached evaluation *)
  | Eval_error of string  (** the gated [eval] op rejected its payload at the boundary *)

let to_string = function
  | Match_failure scrutinee -> Printf.sprintf "no clause matched the value %s" scrutinee
  | Unhandled { effect_; op } ->
      Printf.sprintf "unhandled effect %s: operation `%s` reached the root without a handler"
        effect_ op
  | Arity msg -> "arity mismatch: " ^ msg
  | Type_error msg -> "type error: " ^ msg
  | Unresolved msg -> "unresolved reference: " ^ msg
  | Eval_error msg -> "eval rejected its argument: " ^ msg

let pp fmt t = Format.pp_print_string fmt (to_string t)
