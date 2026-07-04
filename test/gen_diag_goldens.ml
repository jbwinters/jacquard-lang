(* Regenerates corpus/golden/diags.golden. Run: dune exec test/gen_diag_goldens.exe *)

open Weft

let () =
  match Corpus_support.diag_golden_lines ~prelude_dir:"prelude" with
  | Error ds ->
      prerr_endline (String.concat "; " (List.map Diag.to_string ds));
      exit 1
  | Ok lines ->
      let oc = open_out_bin "corpus/golden/diags.golden" in
      List.iter (fun l -> output_string oc (l ^ "\n")) lines;
      close_out oc;
      Printf.printf "wrote %d lines to corpus/golden/diags.golden\n" (List.length lines)
