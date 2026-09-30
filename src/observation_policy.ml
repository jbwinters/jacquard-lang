(** Versioned observation policies (OBS.1). See [observation_policy.mli]. *)

let format_version = 1

type arguments = All_arguments | No_arguments | Selected_arguments of int list
type field = Compare | Ignore
type rule = { arguments : arguments; result : field; output : field }

type t = {
  result : field;
  field_bytes : int;
  unlisted : rule option;
  interface : Hash.t option;
  operations : (Hash.t * rule) list;  (** sorted by identity, no repeats *)
}

let policy_error cause =
  Error
    [
      Diag.error ~domain:Warp ~code:"E1005" ~summary:"The observation policy is invalid or refused."
        ~cause
        ~next_step:
          "Write the policy in canonical observation-policy-v1 form and name only operations and \
           an interface identity of the observed program."
        ~contrast:None ();
    ]

let rec ascending = function
  | first :: (second :: _ as rest) -> first < second && ascending rest
  | [ _ ] | [] -> true

let valid_rule { arguments; _ } =
  match arguments with
  | Selected_arguments [] -> Error "a selected-argument list is empty (write none instead)"
  | Selected_arguments positions ->
      if List.exists (fun position -> position < 0) positions then
        Error "an argument position is negative"
      else if not (ascending positions) then
        Error "argument positions are repeated or not ascending"
      else Ok ()
  | All_arguments | No_arguments -> Ok ()

let make ~result ~field_bytes ~unlisted ~interface operations =
  let ( let* ) = Result.bind in
  let operations = List.sort (fun (left, _) (right, _) -> Hash.compare left right) operations in
  let rec distinct = function
    | (first, _) :: ((second, _) :: _ as rest) -> (not (Hash.equal first second)) && distinct rest
    | [ _ ] | [] -> true
  in
  let checked =
    let* () = if field_bytes > 0 then Ok () else Error "the field byte limit is not positive" in
    let* () = if distinct operations then Ok () else Error "an operation is listed twice" in
    let* () = match unlisted with Some rule -> valid_rule rule | None -> Ok () in
    List.fold_left
      (fun checked (_, rule) -> Result.bind checked (fun () -> valid_rule rule))
      (Ok ()) operations
  in
  match checked with
  | Error cause -> policy_error cause
  | Ok () -> Ok { result; field_bytes; unlisted; interface; operations }

let default =
  {
    result = Compare;
    field_bytes = 4096;
    unlisted = Some { arguments = All_arguments; result = Ignore; output = Compare };
    interface = None;
    operations = [];
  }

let result policy = policy.result
let field_bytes policy = policy.field_bytes
let interface policy = policy.interface
let operations policy = policy.operations

let rule_for policy operation =
  match List.find_opt (fun (listed, _) -> Hash.equal listed operation) policy.operations with
  | Some (_, rule) -> Some rule
  | None -> policy.unlisted

(* canonical encoding *)

let field_word = function Compare -> "compare" | Ignore -> "ignore"

let arguments_word = function
  | All_arguments -> "all"
  | No_arguments -> "none"
  | Selected_arguments positions -> String.concat "," (List.map string_of_int positions)

let rule_fields rule =
  Printf.sprintf "arguments=%s result=%s output=%s" (arguments_word rule.arguments)
    (field_word rule.result) (field_word rule.output)

let serialize policy =
  let buffer = Buffer.create 256 in
  Printf.bprintf buffer "jacquard-observation-policy format=%d\n" format_version;
  Printf.bprintf buffer "result=%s field-bytes=%d interface=%s\n" (field_word policy.result)
    policy.field_bytes
    (match policy.interface with Some identity -> Hash.to_hex identity | None -> "none");
  (match policy.unlisted with
  | None -> Buffer.add_string buffer "unlisted=ignore\n"
  | Some rule -> Printf.bprintf buffer "unlisted=record %s\n" (rule_fields rule));
  Printf.bprintf buffer "operations=%d\n" (List.length policy.operations);
  List.iter
    (fun (operation, rule) ->
      Printf.bprintf buffer "operation=%s %s\n" (Hash.to_hex operation) (rule_fields rule))
    policy.operations;
  Buffer.contents buffer

let identity policy = Hash.of_string ("jacquard-observation-policy-v1\000" ^ serialize policy)

(* strict decoding *)

let invalid_at offset detail =
  policy_error (Printf.sprintf "Invalid observation policy at byte offset %d: %s" offset detail)

let diagnostics_at offset detail = Result.get_error (invalid_at offset detail)
let expect cursor literal = Strict_cursor.expect_literal ~invalid:diagnostics_at cursor literal
let unsigned cursor = Strict_cursor.parse_unsigned ~invalid:diagnostics_at cursor

let parse_field cursor =
  let offset = cursor.Strict_cursor.offset in
  match Strict_cursor.parse_word cursor with
  | "compare" -> Ok Compare
  | "ignore" -> Ok Ignore
  | _ -> invalid_at offset "a field choice is neither compare nor ignore"

let parse_arguments cursor =
  let ( let* ) = Result.bind in
  let offset = cursor.Strict_cursor.offset in
  if Strict_cursor.peek_literal cursor "all" then
    let* () = expect cursor "all" in
    Ok All_arguments
  else if Strict_cursor.peek_literal cursor "none" then
    let* () = expect cursor "none" in
    Ok No_arguments
  else
    let rec positions reversed =
      let* position = unsigned cursor in
      if Strict_cursor.peek_literal cursor "," then
        let* () = expect cursor "," in
        positions (position :: reversed)
      else Ok (List.rev (position :: reversed))
    in
    match positions [] with
    | Ok positions -> Ok (Selected_arguments positions)
    | Error _ -> invalid_at offset "an argument selection is not all, none, or ascending positions"

let parse_rule cursor =
  let ( let* ) = Result.bind in
  let* () = expect cursor "arguments=" in
  let* arguments = parse_arguments cursor in
  let* () = expect cursor " result=" in
  let* result = parse_field cursor in
  let* () = expect cursor " output=" in
  let* output = parse_field cursor in
  Ok { arguments; result; output }

let parse bytes =
  let ( let* ) = Result.bind in
  let cursor = Strict_cursor.create bytes in
  let* () = expect cursor "jacquard-observation-policy format=" in
  let* version = unsigned cursor in
  let* () =
    if version = format_version then Ok ()
    else invalid_at cursor.offset "the policy format version is unsupported"
  in
  let* () = expect cursor "\nresult=" in
  let* result = parse_field cursor in
  let* () = expect cursor " field-bytes=" in
  let* field_bytes = unsigned cursor in
  let* () = expect cursor " interface=" in
  let* interface =
    if Strict_cursor.peek_literal cursor "none" then
      Result.map (fun () -> None) (expect cursor "none")
    else Result.map Option.some (Strict_cursor.parse_hash ~invalid:diagnostics_at cursor)
  in
  let* () = expect cursor "\nunlisted=" in
  let* unlisted =
    if Strict_cursor.peek_literal cursor "ignore" then
      Result.map (fun () -> None) (expect cursor "ignore")
    else
      let* () = expect cursor "record " in
      Result.map Option.some (parse_rule cursor)
  in
  let* () = expect cursor "\noperations=" in
  let* count = unsigned cursor in
  let* () = expect cursor "\n" in
  let rec listed remaining reversed =
    if remaining = 0 then Ok (List.rev reversed)
    else
      let* () = expect cursor "operation=" in
      let* operation = Strict_cursor.parse_hash ~invalid:diagnostics_at cursor in
      let* () = expect cursor " " in
      let* rule = parse_rule cursor in
      let* () = expect cursor "\n" in
      listed (remaining - 1) ((operation, rule) :: reversed)
  in
  let* operations = listed count [] in
  let* () =
    if Strict_cursor.at_end cursor then Ok ()
    else invalid_at cursor.offset "bytes remain after the final operation"
  in
  let* policy = make ~result ~field_bytes ~unlisted ~interface operations in
  if String.equal (serialize policy) bytes then Ok policy
  else invalid_at 0 "the decoded policy is not in canonical order"

let validate_operations policy ~is_operation =
  match List.filter (fun (operation, _) -> not (is_operation operation)) policy.operations with
  | [] -> Ok ()
  | (operation, _) :: _ ->
      policy_error
        (Printf.sprintf "The policy lists %s, which is not an operation of the observed program."
           (Hash.to_hex operation))

let check_interface policy ~identity =
  match policy.interface with
  | None -> Ok ()
  | Some pinned when Hash.equal pinned identity -> Ok ()
  | Some pinned ->
      policy_error
        (Printf.sprintf
           "The policy is pinned to interface %s, but the observed program's interface is %s."
           (Hash.to_hex pinned) (Hash.to_hex identity))
