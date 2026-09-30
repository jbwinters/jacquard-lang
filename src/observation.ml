(** Typed observation of facts at the evaluator root (RF.3). See [observation.mli]. *)

type event =
  | Operation of { operation : Hash.t; name : string; arguments : Value.t list }
  | Output of { operation : Hash.t; bytes : string }
  | Result of { operation : Hash.t; result : (Value.t, Runtime_err.t) result }

let operation = function
  | Operation { operation; _ } | Output { operation; _ } | Result { operation; _ } -> operation
