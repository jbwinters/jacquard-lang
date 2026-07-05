(** The uniform triple representation (spec §2): every Jacquard form is [(head, meta, args)].
    Scalars appear only as leaves inside [args]; everything else is a triple. This is the single
    physical shape of all Jacquard code. *)

type arg = F of t | Int of int | Real of float | Text of string | Sym of string | Hash of Hash.t
and t = { head : string; meta : Meta.t; args : arg list }

(** [form head args] builds a triple with optional metadata (default empty). *)
let form ?(meta = Meta.empty) head args = { head; meta; args }

(** Structural equality with all metadata erased, recursively. Real leaves compare with
    [Float.compare], so [nan] equals [nan] and [-0.] equals [0.]; canonical hashing (W1.5) pins the
    bit-level story. *)
let rec equal_ignoring_meta (a : t) (b : t) =
  String.equal a.head b.head && List.equal equal_arg a.args b.args

and equal_arg a b =
  match (a, b) with
  | F a, F b -> equal_ignoring_meta a b
  | Int a, Int b -> Int.equal a b
  | Real a, Real b -> Float.compare a b = 0
  | Text a, Text b | Sym a, Sym b -> String.equal a b
  | Hash a, Hash b -> Hash.equal a b
  | (F _ | Int _ | Real _ | Text _ | Sym _ | Hash _), _ -> false

let span t = Meta.span t.meta

let rec pp fmt { head; args; _ } =
  Format.fprintf fmt "@[<hov 1>(%s" head;
  List.iter (fun a -> Format.fprintf fmt "@ %a" pp_arg a) args;
  Format.fprintf fmt ")@]"

and pp_arg fmt = function
  | F f -> pp fmt f
  | Int i -> Format.pp_print_int fmt i
  | Real r -> Format.fprintf fmt "%h" r
  | Text s -> Format.fprintf fmt "%S" s
  | Sym s -> Format.fprintf fmt "'%s" s
  | Hash h -> Format.fprintf fmt "#%a" Hash.pp h

let to_string t = Format.asprintf "%a" pp t
