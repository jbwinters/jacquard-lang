(** Content hashes, decision D1: SHA-256 via digestif, named [HASH_V0].

    The algorithm is swappable behind this module; nothing outside it may assume SHA-256. Values are
    stored as raw digest bytes and rendered as lowercase hex. *)

type t = Digest_bytes of string  (** raw digest bytes, length [digest_size] *)

let algorithm = "HASH_V0"
let digest_size = Digestif.SHA256.digest_size

(** [of_string s] hashes the bytes of [s] with [HASH_V0]. *)
let of_string s = Digest_bytes Digestif.SHA256.(to_raw_string (digest_string s))

(** [to_raw h] is the raw digest bytes (length [digest_size]); used by canonical serialization. *)
let to_raw (Digest_bytes raw) = raw

let to_hex (Digest_bytes raw) =
  let buf = Buffer.create (2 * String.length raw) in
  String.iter (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) raw;
  Buffer.contents buf

(** [of_hex s] parses a full lowercase/uppercase hex digest. Returns [None] on wrong length or
    non-hex characters. *)
let of_hex s =
  if String.length s <> 2 * digest_size then None
  else
    let ok = ref true in
    let byte i =
      let v c =
        match c with
        | '0' .. '9' -> Char.code c - Char.code '0'
        | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
        | 'A' .. 'F' -> Char.code c - Char.code 'A' + 10
        | _ ->
            ok := false;
            0
      in
      Char.chr ((v s.[2 * i] * 16) + v s.[(2 * i) + 1])
    in
    let raw = String.init digest_size byte in
    if !ok then Some (Digest_bytes raw) else None

let equal (Digest_bytes a) (Digest_bytes b) = String.equal a b
let compare (Digest_bytes a) (Digest_bytes b) = String.compare a b
let pp fmt t = Format.pp_print_string fmt (to_hex t)
