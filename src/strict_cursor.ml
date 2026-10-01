(** A byte cursor for strict, canonical line formats (observation policies and transcripts). Every
    reader reports only a structural location through the caller's [invalid] function (which builds
    the diagnostics for a byte offset and a detail), never input bytes. Internal to the observation
    formats. *)

type t = { bytes : string; mutable offset : int }

let create bytes = { bytes; offset = 0 }
let at_end cursor = cursor.offset = String.length cursor.bytes

let expect_literal ~invalid cursor literal =
  let input_length = String.length cursor.bytes in
  let literal_length = String.length literal in
  let rec check index =
    if index = literal_length then (
      cursor.offset <- cursor.offset + literal_length;
      Ok ())
    else
      let input_index = cursor.offset + index in
      if input_index >= input_length then
        Error (invalid input_index "a structural field is truncated")
      else if cursor.bytes.[input_index] <> literal.[index] then
        Error
          (invalid input_index "a structural field is misspelled, reordered, or incorrectly spaced")
      else check (index + 1)
  in
  check 0

(** [peek_literal cursor literal] holds when the input continues with [literal]; it consumes
    nothing. *)
let peek_literal cursor literal =
  let literal_length = String.length literal in
  cursor.offset + literal_length <= String.length cursor.bytes
  && String.equal (String.sub cursor.bytes cursor.offset literal_length) literal

let parse_unsigned ~invalid cursor =
  let input_length = String.length cursor.bytes in
  let start = cursor.offset in
  let digit_at index =
    if index >= input_length then None
    else
      match cursor.bytes.[index] with
      | '0' .. '9' as char -> Some (Char.code char - Char.code '0')
      | _ -> None
  in
  match digit_at start with
  | None -> Error (invalid start "an unsigned decimal field has no digits")
  | Some _ ->
      let rec scan index value =
        match digit_at index with
        | None -> Ok (index, value)
        | Some digit ->
            if value > (max_int - digit) / 10 then
              Error (invalid index "an unsigned decimal field exceeds the supported range")
            else scan (index + 1) ((value * 10) + digit)
      in
      Result.bind (scan start 0) (fun (stop, value) ->
          if cursor.bytes.[start] = '0' && stop - start > 1 then
            Error (invalid start "an unsigned decimal field has a leading zero")
          else (
            cursor.offset <- stop;
            Ok value))

let read_payload ~invalid cursor byte_length =
  let available = String.length cursor.bytes - cursor.offset in
  if byte_length > available then Error (invalid cursor.offset "a declared payload is truncated")
  else
    let payload = String.sub cursor.bytes cursor.offset byte_length in
    cursor.offset <- cursor.offset + byte_length;
    Ok payload

let parse_hash ~invalid cursor =
  let hash_length = 2 * Hash.digest_size in
  let available = String.length cursor.bytes - cursor.offset in
  if hash_length > available then Error (invalid cursor.offset "a hash is truncated")
  else
    let raw = String.sub cursor.bytes cursor.offset hash_length in
    match Hash.of_canonical_hex raw with
    | None -> Error (invalid cursor.offset "a hash is not canonical lowercase HASH_V0")
    | Some hash ->
        cursor.offset <- cursor.offset + hash_length;
        Ok hash

(** [parse_word cursor] reads the maximal run of [A-Za-z0-9-] characters; it may be empty. *)
let parse_word cursor =
  let input_length = String.length cursor.bytes in
  let rec scan index =
    if index < input_length then
      match cursor.bytes.[index] with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' -> scan (index + 1)
      | _ -> index
    else index
  in
  let start = cursor.offset in
  let stop = scan start in
  cursor.offset <- stop;
  String.sub cursor.bytes start (stop - start)
