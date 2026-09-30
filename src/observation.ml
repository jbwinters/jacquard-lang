(** Typed observation of facts at the evaluator root (RF.3). See [observation.mli]. *)

type value =
  | Int of int
  | Real of float
  | Text of string
  | Hash of Hash.t
  | Tuple of value list
  | Constructor of { identity : Hash.t; name : string; arguments : value list }
  | Code of Form.t
  | Opaque of string

type event =
  | Operation of { operation : Hash.t; name : string; arguments : value list Lazy.t }
  | Output of { operation : Hash.t; bytes : string }
  | Result of { operation : Hash.t; result : (value, Runtime_err.t) result Lazy.t }

let rec of_value (v : Value.t) =
  (* the projection walks the whole value: it draws on computation fuel like any other walk *)
  Fuel_meter.tick 1;
  match v with
  | Value.VInt i -> Int i
  | Value.VReal r -> Real r
  | Value.VText s ->
      Fuel_meter.tick (String.length s);
      Text s
  | Value.VHash h -> Hash h
  | Value.VTuple items -> Tuple (List.map of_value items)
  | Value.VCon { con; name; args } ->
      Constructor { identity = con; name; arguments = List.map of_value args }
  | Value.VCode form -> Code form
  | Value.VSecret _ -> Opaque "secret"
  | Value.VClosure _ -> Opaque "closure"
  | Value.VResume _ | Value.VOnceResume _ -> Opaque "resumption"
  | Value.VBuiltin _ | Value.VTrustedBuiltin _ -> Opaque "builtin"
  | Value.VOp _ -> Opaque "operation"
  | Value.VConstructor _ -> Opaque "constructor"
  | Value.VTask _ -> Opaque "task"
  | Value.VChannel _ -> Opaque "channel"

let rec render v =
  (* rendering walks the value too, so it draws on fuel like the projection *)
  Fuel_meter.tick 1;
  match v with
  | Int i -> string_of_int i
  | Real r -> Printer.real_repr r
  | Text s ->
      Fuel_meter.tick (String.length s);
      "\"" ^ Printer.escape_text s ^ "\""
  | Hash h -> "#" ^ Hash.to_hex h
  | Tuple items -> "(" ^ String.concat ", " (List.map render items) ^ ")"
  | Constructor { name; arguments = []; _ } -> name
  | Constructor { name; arguments; _ } ->
      name ^ "(" ^ String.concat ", " (List.map render arguments) ^ ")"
  | Code form -> "(quote " ^ Printer.inline_form form ^ ")"
  | Opaque kind -> "<" ^ kind ^ ">"

let operation = function
  | Operation { operation; _ } | Output { operation; _ } | Result { operation; _ } -> operation
