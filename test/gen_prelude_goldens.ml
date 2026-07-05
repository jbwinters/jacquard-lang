(* Regenerates corpus/golden/prelude-hashes.golden from prelude/.
   Run from the repo root: dune exec test/gen_prelude_goldens.exe *)

open Jacquard

let () =
  let dir = if Array.length Sys.argv > 1 then Sys.argv.(1) else "prelude" in
  let out =
    if Array.length Sys.argv > 2 then Sys.argv.(2) else "corpus/golden/prelude-hashes.golden"
  in
  let root =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-prelude-gen-%d" (Unix.getpid ()))
  in
  let store =
    match Store.open_store root with
    | Ok s -> s
    | Error ds ->
        prerr_endline (String.concat "; " (List.map Diag.to_string ds));
        exit 1
  in
  match Prelude.load ~dir store with
  | Error ds ->
      prerr_endline (String.concat "; " (List.map Diag.to_string ds));
      exit 1
  | Ok files ->
      let lines =
        List.concat_map
          (fun (file, hashes) ->
            List.concat
              (List.mapi
                 (fun i { Canon.decl_hash; named } ->
                   Printf.sprintf "%s:%d %s" file i (Hash.to_hex decl_hash)
                   :: List.map
                        (fun (n, h) -> Printf.sprintf "%s:%d:%s %s" file i n (Hash.to_hex h))
                        named)
                 hashes))
          files
      in
      let oc = open_out_bin out in
      List.iter (fun l -> output_string oc (l ^ "\n")) lines;
      close_out oc;
      Printf.printf "wrote %d lines to %s\n" (List.length lines) out
