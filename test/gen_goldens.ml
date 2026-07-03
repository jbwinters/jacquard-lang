(* Regenerates corpus/golden/hashes.golden from corpus/valid/.
   Run from the repo root: dune exec test/gen_goldens.exe *)

let () =
  let valid_dir = if Array.length Sys.argv > 1 then Sys.argv.(1) else "corpus/valid" in
  let out = if Array.length Sys.argv > 2 then Sys.argv.(2) else "corpus/golden/hashes.golden" in
  let lines = Corpus_support.corpus_golden_lines ~valid_dir in
  let oc = open_out_bin out in
  List.iter (fun l -> output_string oc (l ^ "\n")) lines;
  close_out oc;
  Printf.printf "wrote %d lines to %s\n" (List.length lines) out
