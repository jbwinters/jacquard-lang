(* PKG.1: the project-context-v1 record (design §8); contracts in project_context.mli. *)

let rec closure store seen = function
  | [] -> seen
  | hash :: rest -> (
      match Store.locate store hash with
      | Error _ -> closure store seen rest
      | Ok { Store.decl_hash; decl; _ } ->
          if List.exists (Hash.equal decl_hash) seen then closure store seen rest
          else closure store (decl_hash :: seen) (Store.decl_refs decl @ rest))

let form store ~interface ~exports ~deps =
  let decls = closure store [] (List.map snd exports) in
  let in_closure hash =
    match Store.locate store hash with
    | Ok { Store.decl_hash; _ } -> List.exists (Hash.equal decl_hash) decls
    | Error _ -> false
  in
  let companions =
    List.sort
      (fun (a, _) (b, _) -> Hash.compare a b)
      (List.filter (fun (hash, _) -> in_closure hash) store.Store.call_abis)
  in
  let prelude =
    List.map
      (fun (file, digest) -> Form.F (Form.form "file" [ Form.Text file; Form.Text digest ]))
      (List.sort compare (Option.value ~default:[] (Store.prelude_manifest store)))
  in
  Form.form "project-context-v1"
    [
      Form.F (Form.form "interface" [ Form.Hash (Interface.identity interface) ]);
      Form.F
        (Form.form "companions"
           (List.map
              (fun (hash, slots) ->
                Form.F
                  (Form.form "call-abi-v1"
                     (Form.Hash hash
                     :: List.map (fun slot -> Form.F (Store.call_abi_slot_form slot)) slots)))
              companions));
      Form.F (Form.form "prelude" prelude);
      Form.F (Form.form "core" [ Form.Text Version.version ]);
      Form.F
        (Form.form "deps"
           (List.map
              (fun (alias, identity) ->
                Form.F (Form.form "dep" [ Form.Sym alias; Form.Hash identity ]))
              (List.sort compare deps)));
    ]

let identity form = Hash.of_string (Printer.print form)
