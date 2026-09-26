(* SX.31: the prelude constructors that surface sugar elaborates to, by identity; contracts in
   sugar_identity.mli. *)

let constructors =
  [
    ("true", "bf5c9d86f11ef2591a2f1b7b9dcbc26342dcb093fce099341ce56e14b75482fb");
    ("false", "c665b4997cada5268e43d722a9da3883b9eddd5e10ef5b1d39ee5c0034390e8c");
    ("nil", "a3213f58f1ac022ec4bc77f4b50465e29552fc2badb73c62df89f1e9fe57e382");
    ("cons", "e085c120bdafd78f89fc8ec87b699ce57c93e93145d70387d55097390e8f5752");
    ("ok", "fc7e8018da11f1e0cc0c516bd50c27c8c3900881df816e50cb7881d8a2f490cc");
    ("err", "6bf597bd76a9d52fa2405404f03511f07bafdb7620c8e45d9faf9a9a5aa88cee");
  ]

(* the [surface-generated] forms whose constructor reference the sugar itself introduced *)
let sugar_forms =
  [
    "if-true";
    "if-false";
    "list";
    "list-nil";
    "list-cons-constructor";
    "try-ok";
    "try-err";
    "try-err-constructor";
  ]

(* generated constructor calls record their form as [surface-generated]; generated patterns as
   [surface-form] *)
let prelude_constructor ~meta name =
  let generated =
    List.exists
      (function Some form -> List.mem form sugar_forms | None -> false)
      [ Meta.surface_generated meta; Meta.surface_form meta ]
  in
  if generated then Option.bind (List.assoc_opt name constructors) Hash.of_hex else None
