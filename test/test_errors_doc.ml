(* W5.3: every diagnostic code emitted anywhere in src/, bin/, or runtime/ appears in docs/errors.md
   (the catalog is the contract; this test is its teeth). *)

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let rec source_files dir =
  Sys.readdir dir |> Array.to_list
  |> List.concat_map (fun entry ->
      let path = Filename.concat dir entry in
      if Sys.is_directory path then source_files path
      else if List.exists (Filename.check_suffix path) [ ".ml"; ".c"; ".h" ] then [ path ]
      else [])

(* every string literal that looks like a diagnostic code passed to ~code: (or bound as an
   optional-parameter default, `?(x_code = "...")`) *)
let emitted_codes () =
  let re = Str.regexp {|"\([EWI][0-9][0-9][0-9][0-9]\)"|} in
  let codes = Hashtbl.create 64 in
  List.iter
    (fun path ->
      let src = read_file path in
      let rec scan pos =
        match Str.search_forward re src pos with
        | i ->
            Hashtbl.replace codes (Str.matched_group 1 src) ();
            scan (i + 1)
        | exception Not_found -> ()
      in
      scan 0)
    (source_files "../src" @ source_files "../bin" @ source_files "../runtime");
  List.sort compare (Hashtbl.fold (fun c () acc -> c :: acc) codes [])

let test_all_codes_cataloged () =
  let doc = read_file "../docs/errors.md" in
  let codes = emitted_codes () in
  Alcotest.(check bool) "found a plausible number of codes" true (List.length codes > 30);
  List.iter
    (fun code ->
      let has =
        let n = String.length code and m = String.length doc in
        let rec go i = i + n <= m && (String.sub doc i n = code || go (i + 1)) in
        go 0
      in
      Alcotest.(check bool) (code ^ " appears in docs/errors.md") true has)
    codes

let suite = [ Alcotest.test_case "all emitted codes cataloged" `Quick test_all_codes_cataloged ]
