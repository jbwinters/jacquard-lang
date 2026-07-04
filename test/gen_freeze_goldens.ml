(* Regenerates corpus/golden/ring0-freeze.golden — the SL.9 freeze artifact:
   every ring-0 name with its elaborated signature.
   Run from the repo root: dune exec test/gen_freeze_goldens.exe *)

open Weft

let () =
  match Corpus_support.freeze_lines ~prelude_dir:"prelude" ~manifest:"prelude/rings.manifest" with
  | Error ds ->
      prerr_endline (String.concat "; " (List.map Diag.to_string ds));
      exit 1
  | Ok lines ->
      let oc = open_out_bin "corpus/golden/ring0-freeze.golden" in
      List.iter (fun l -> output_string oc (l ^ "\n")) lines;
      close_out oc;
      Printf.printf "wrote %d lines to corpus/golden/ring0-freeze.golden\n" (List.length lines)
