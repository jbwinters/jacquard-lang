(* W5.3: every diagnostic code emitted anywhere in src/ or bin/ appears in docs/errors.md
   (the catalog is the contract; this test is its teeth). *)

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let ml_files dir =
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".ml")
  |> List.map (Filename.concat dir)

(* every string literal that looks like a diagnostic code passed to ~code: *)
let emitted_codes () =
  let re = Str.regexp {|code:"\([EW][0-9][0-9][0-9][0-9]\)"|} in
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
    (ml_files "../src" @ ml_files "../bin");
  (* codes built via ~unbound_code defaults and variables *)
  Hashtbl.replace codes "E0812" ();
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
