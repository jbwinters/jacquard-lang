(* Regenerates spec/host-protocol-v0/kit/kit.json and transcripts.json by installing the kit
   fixtures with the published recipe and playing every HB.1 vector through the installed worker.
   Run from the repository root: `dune exec test/gen_host_kit.exe`. *)

let () =
  let kit = Host_kit.kit_dir () in
  let binary = Host_kit.default_binary () in
  let store = Host_kit.fresh_path "store" in
  (match
     Host_kit.build_store ~binary
       ~fixtures:(Filename.concat kit "fixtures.jac")
       ~prelude:(Host_kit.prelude_dir ()) ~store
   with
  | Ok () -> ()
  | Error message ->
      prerr_endline ("gen_host_kit: " ^ message);
      exit 1);
  let store_handle =
    match Jacquard.Store.open_store store with
    | Ok handle -> handle
    | Error diagnostics ->
        prerr_endline (String.concat "\n" (List.map Jacquard.Diag.to_string diagnostics));
        exit 1
  in
  let ids =
    match Host_kit.identities_of_store store_handle with
    | Ok ids -> ids
    | Error message ->
        prerr_endline ("gen_host_kit: " ^ message);
        exit 1
  in
  let doc = Host_kit.load_vectors (Filename.concat (Filename.dirname kit) "vectors.json") in
  let transcripts =
    List.map
      (fun case ->
        let observed = Host_kit.play ~binary ~store case in
        Host_kit.transcript_of case observed)
      (Host_kit.cases doc ids)
  in
  let pending =
    List.filter_map
      (fun transcript ->
        match Host_kit.member "status" transcript with
        | `String "diverges" ->
            Some
              (`Assoc
                 [
                   ("name", Host_kit.member "name" transcript);
                   ("expected", Host_kit.member "code" (Host_kit.member "expect" transcript));
                   ( "observed",
                     Host_kit.member "primary_code" (Host_kit.member "observed" transcript) );
                 ])
        | _ -> None)
      transcripts
  in
  let manifest = Host_kit.manifest ~ids ~doc ~transcripts ~pending in
  Host_kit.write_file (Filename.concat kit "kit.json")
    (Yojson.Safe.pretty_to_string (Host_kit.canonical manifest) ^ "\n");
  Host_kit.write_file
    (Filename.concat kit "transcripts.json")
    (Yojson.Safe.pretty_to_string (`List transcripts) ^ "\n");
  Printf.printf "host kit: %d transcripts, %d diverging\n" (List.length transcripts)
    (List.length pending)
