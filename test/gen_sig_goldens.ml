(* Regenerates corpus/golden/sigs.golden from corpus/sigs/.
   Run from the repo root: dune exec test/gen_sig_goldens.exe *)

open Weft

let () =
  match Corpus_support.sig_lines ~prelude_dir:"prelude" ~sigs_dir:"corpus/sigs" with
  | Error ds ->
      prerr_endline (String.concat "; " (List.map Diag.to_string ds));
      exit 1
  | Ok lines ->
      let oc = open_out_bin "corpus/golden/sigs.golden" in
      List.iter (fun l -> output_string oc (l ^ "\n")) lines;
      close_out oc;
      Printf.printf "wrote %d lines to corpus/golden/sigs.golden\n" (List.length lines)
