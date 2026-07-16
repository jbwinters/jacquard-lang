open Jacquard

let fail fmt =
  Printf.ksprintf
    (fun message ->
      prerr_endline message;
      exit 1)
    fmt

let read_file path =
  let input = open_in_bin path in
  let contents = really_input_string input (in_channel_length input) in
  close_in input;
  contents

let rows path =
  read_file path |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
      let line = String.trim line in
      if String.equal line "" || String.starts_with ~prefix:"#" line then None
      else
        match String.split_on_char ' ' line with
        | [ qualified; "once" ] -> (
            match String.split_on_char '.' qualified with
            | [ effect_name; op_name ] -> Some (effect_name, op_name)
            | _ -> fail "malformed operation name %s" qualified)
        | [ _; "multi" ] -> None
        | _ -> fail "malformed operation-mode row %s" line)

let locate_operation store effect_name op_name =
  match Store.lookup_kind store effect_name Resolve.KEffect with
  | None -> fail "missing effect %s" effect_name
  | Some { Resolve.hash; _ } -> (
      match Store.locate store hash with
      | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ }; _ } -> (
          match List.find_opt (fun (op : Kernel.opspec) -> String.equal op.op_name op_name) ops with
          | Some ({ op_mode = Kernel.Once; _ } as operation) -> operation
          | Some _ -> fail "%s.%s is not declared once" effect_name op_name
          | None -> fail "missing operation %s.%s" effect_name op_name)
      | _ -> fail "%s is not a stored effect" effect_name)

let app name args = Printf.sprintf "(app (var %s)%s)" name (String.concat "" args)
let var name = " (var " ^ name ^ ")"

let source op_name arity =
  let outer = List.init arity (fun index -> "a" ^ string_of_int index) in
  let inner = List.init arity (fun index -> "p" ^ string_of_int index) in
  let pats names = String.concat "" (List.map (fun name -> " (pvar " ^ name ^ ")") names) in
  let recurse = app op_name (List.map var inner) in
  Printf.sprintf
    "(lam (%s)\n\
    \  (handle %s\n\
    \    (ret (pvar answer) (var answer))\n\
    \    (opclause %s (%s) k\n\
    \      (let nonrec (pwild) (app (var k) %s)\n\
    \        (app (var k) %s)))))\n"
    (pats outer)
    (app op_name (List.map var outer))
    op_name (pats inner) recurse recurse

let () =
  if Array.length Sys.argv <> 4 then
    fail "usage: gen_once_hostile PRELUDE_DIR MODE_MANIFEST OUTPUT_DIR";
  let prelude_dir, manifest, output_dir = (Sys.argv.(1), Sys.argv.(2), Sys.argv.(3)) in
  if not (Sys.file_exists output_dir) then Unix.mkdir output_dir 0o755;
  let store_dir = Filename.concat output_dir ".store" in
  let store =
    match Store.open_store store_dir with
    | Ok store -> store
    | Error diagnostics -> fail "%s" (String.concat "; " (List.map Diag.to_string diagnostics))
  in
  (match Prelude.load ~dir:prelude_dir store with
  | Ok _ -> ()
  | Error diagnostics -> fail "%s" (String.concat "; " (List.map Diag.to_string diagnostics)));
  let once = rows manifest in
  List.iter
    (fun (effect_name, op_name) ->
      let operation = locate_operation store effect_name op_name in
      let path = Filename.concat output_dir (effect_name ^ "-" ^ op_name ^ ".jqd") in
      let output = open_out_bin path in
      output_string output (source op_name (List.length operation.Kernel.op_params));
      close_out output)
    once;
  Printf.printf "generated %d once-hostile cases from reviewed inventory\n" (List.length once)
