(* Generates the prelude identity pins (TYPE.1) from corpus/golden/prelude-bindings.golden, whose
   lines are `NAME KIND HEX`: the prelude's public bindings, kept current by the prelude golden
   test. *)

let () =
  let pins =
    In_channel.with_open_bin Sys.argv.(1) In_channel.input_all
    |> String.split_on_char '\n'
    |> List.filter_map (fun line ->
        match String.split_on_char ' ' line with
        | [ name; kind; hex ] -> Some (name, kind, hex)
        | [ "" ] -> None
        | _ ->
            prerr_endline ("pins_gen: malformed golden line: " ^ line);
            exit 1)
  in
  print_string
    "(* Generated from corpus/golden/prelude-bindings.golden by src/pins_gen; do not edit. *)\n\n";
  print_string "let pins : (string * string * string) list =\n  [\n";
  List.iter (fun (name, kind, hex) -> Printf.printf "    (%S, %S, %S);\n" name kind hex) pins;
  print_string "  ]\n"
