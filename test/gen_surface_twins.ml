open Jacquard

let fail stage file diagnostics =
  prerr_endline
    (Printf.sprintf "%s failed at %s:\n%s" file (Corpus_support.stage_name stage)
       (String.concat "\n" (List.map Diag.to_string diagnostics)));
  exit 1

let curated_twins valid_dir =
  let path = Filename.concat valid_dir "twins.curated" in
  if not (Sys.file_exists path) then []
  else
    Corpus_support.read_file path |> String.split_on_char '\n' |> List.map String.trim
    |> List.filter (fun line -> line <> "" && line.[0] <> '#')

let lookup kind hash =
  let matching_kind entry_kind =
    match (kind, entry_kind) with
    | Surface_name.Term, Resolve.KTerm
    | Surface_name.Op, Resolve.KOp
    | Surface_name.Type, Resolve.KType
    | Surface_name.Con, Resolve.KCon
    | Surface_name.Effect, Resolve.KEffect ->
        true
    | Surface_name.Tvar, _ | Surface_name.Rvar, _ | _, _ -> false
  in
  List.find_map
    (fun (name, entry) ->
      if matching_kind entry.Resolve.kind && Hash.equal hash entry.hash then Some name else None)
    Corpus_support.stub_entries

let write_twin valid_dir curated file =
  let bootstrap_path = Filename.concat valid_dir file in
  let surface_path = Filename.remove_extension bootstrap_path ^ ".jac" in
  let surface_file = Filename.basename surface_path in
  if List.mem surface_file curated then Printf.printf "curated: %s\n" surface_path
  else
    let source = Corpus_support.read_file bootstrap_path in
    match Corpus_support.bootstrap_tops ~file:bootstrap_path source with
    | Error (stage, diagnostics) -> fail stage bootstrap_path diagnostics
    | Ok tops -> (
        let rec resolve acc = function
          | [] -> List.rev acc
          | top :: rest -> (
              match Resolve.resolve Corpus_support.stub_names top with
              | Ok resolved -> resolve (resolved :: acc) rest
              | Error diagnostics -> fail Corpus_support.Resolve bootstrap_path diagnostics)
        in
        let resolved = resolve [] tops in
        match Surface_print.print_file ~lookup resolved with
        | Error diagnostics -> fail Corpus_support.Validate bootstrap_path diagnostics
        | Ok surface ->
            let channel = open_out_bin surface_path in
            output_string channel surface;
            close_out channel;
            Printf.printf "%s -> %s\n" bootstrap_path surface_path)

let () =
  let valid_dir = if Array.length Sys.argv > 1 then Sys.argv.(1) else "corpus/valid" in
  let files = Corpus_support.jqd_files valid_dir in
  let curated = curated_twins valid_dir in
  List.iter (write_twin valid_dir curated) files;
  Printf.printf "processed %d surface twins (%d curated)\n" (List.length files)
    (List.length curated)
