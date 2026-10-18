(* Cram transcripts record the exit status of a command line's last pipeline stage only. A
   Jacquard tool or script piped into an excerpting filter (`| sed`, `| head`, `| grep`) can
   therefore fail without changing the transcript: that is how a failing release-only demo suite
   once reached release evidence. This law finds every pipeline whose upstream stage runs a tool
   or script; such commands write the output to a file, pin the status, then excerpt:

     jacquard run x.jac > pipe.out 2>&1 || echo "exit=$?"; head -1 < pipe.out *)

let tool_words = [ "jacquard"; "jac"; "sh"; "bash"; "dash" ]

(* Replace quoted strings and $( ) groups with a placeholder word so that only the stage's own
   command words remain. *)
let strip_nested text =
  let n = String.length text in
  let buf = Buffer.create n in
  let rec skip_group i depth =
    if i >= n then n
    else
      match text.[i] with
      | '(' -> skip_group (i + 1) (depth + 1)
      | ')' -> if depth = 0 then i + 1 else skip_group (i + 1) (depth - 1)
      | '\'' -> skip_group (skip_quote (i + 1) '\'') depth
      | '"' -> skip_group (skip_quote (i + 1) '"') depth
      | _ -> skip_group (i + 1) depth
  and skip_quote i q =
    if i >= n then n
    else if text.[i] = '\\' && q = '"' then skip_quote (i + 2) q
    else if text.[i] = q then i + 1
    else skip_quote (i + 1) q
  in
  let rec go i =
    if i < n then
      match text.[i] with
      | '\'' | '"' ->
          Buffer.add_string buf " X ";
          go (skip_quote (i + 1) text.[i])
      | '$' when i + 1 < n && text.[i + 1] = '(' ->
          Buffer.add_string buf " X ";
          go (skip_group (i + 2) 0)
      | c ->
          Buffer.add_char buf c;
          go (i + 1)
  in
  go 0;
  Buffer.contents buf

let is_assignment word =
  match String.index_opt word '=' with
  | Some i when i > 0 ->
      String.for_all
        (fun c ->
          c = '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
        (String.sub word 0 i)
  | _ -> false

let is_number word = word <> "" && String.for_all (fun c -> c >= '0' && c <= '9') word

let runs_tool stage =
  let pieces =
    String.split_on_char '\n' (strip_nested stage)
    |> List.concat_map (fun piece ->
        String.map (function ';' | '&' | '|' | '(' | ')' | '{' | '}' -> '\n' | c -> c) piece
        |> String.split_on_char '\n')
  in
  let command_word piece =
    let words = String.split_on_char ' ' piece |> List.concat_map (String.split_on_char '\t') in
    let words = List.filter (fun w -> w <> "") words in
    let rec first = function
      | ("!" | "env" | "exec" | "timeout" | "do" | "then" | "else") :: rest -> first rest
      | word :: rest when is_assignment word || is_number word -> first rest
      | word :: _ -> Some word
      | [] -> None
    in
    first words
  in
  List.exists
    (fun piece ->
      match command_word piece with
      | None -> false
      | Some word ->
          List.mem word tool_words || Filename.check_suffix word ".sh"
          || Filename.check_suffix word ".exe"
          || String.starts_with ~prefix:"./" word)
    pieces

(* [masked_upstreams cmd] is the upstream stage of every pipe in [cmd] (at any nesting depth,
   including inside $( ) and double quotes) whose stage runs a tool or script. *)
let masked_upstreams cmd =
  let n = String.length cmd in
  let found = ref [] in
  let rec scan_list i stop =
    let stage = ref i in
    let rec go i =
      if i >= n then n
      else
        match cmd.[i] with
        | c when Some c = stop -> i + 1
        | '\\' -> go (i + 2)
        | '\'' -> go (skip_single (i + 1))
        | '"' -> go (scan_double (i + 1))
        | '$' when i + 1 < n && cmd.[i + 1] = '(' -> go (scan_list (i + 2) (Some ')'))
        | '(' -> go (scan_list (i + 1) (Some ')'))
        | '{' when i = 0 || cmd.[i - 1] <> '$' -> go (scan_list (i + 1) (Some '}'))
        | '|' when i + 1 < n && cmd.[i + 1] = '|' ->
            stage := i + 2;
            go (i + 2)
        | '|' ->
            let upstream = String.sub cmd !stage (i - !stage) in
            if runs_tool upstream then found := String.trim upstream :: !found;
            stage := i + 1;
            go (i + 1)
        | '&' when i + 1 < n && cmd.[i + 1] = '&' ->
            stage := i + 2;
            go (i + 2)
        | ';' | '\n' ->
            stage := i + 1;
            go (i + 1)
        | _ -> go (i + 1)
    in
    go i
  and skip_single i = match String.index_from_opt cmd i '\'' with Some j -> j + 1 | None -> n
  and scan_double i =
    if i >= n then n
    else
      match cmd.[i] with
      | '\\' -> scan_double (i + 2)
      | '"' -> i + 1
      | '$' when i + 1 < n && cmd.[i + 1] = '(' -> scan_double (scan_list (i + 2) (Some ')'))
      | _ -> scan_double (i + 1)
  in
  ignore (scan_list 0 None);
  List.rev !found

(* Commands of a cram transcript: each `  $ ` line with its `  > ` continuations, except that a
   here-document body is data, not commands. *)
let commands text =
  let lines = String.split_on_char '\n' text |> Array.of_list in
  let count = Array.length lines in
  let rec collect i acc =
    if i >= count then List.rev acc
    else if String.starts_with ~prefix:"  $ " lines.(i) then (
      let first = String.sub lines.(i) 4 (String.length lines.(i) - 4) in
      let j = ref (i + 1) in
      let body = Buffer.create 80 in
      Buffer.add_string body first;
      while !j < count && String.starts_with ~prefix:"  > " lines.(!j) do
        Buffer.add_char body '\n';
        Buffer.add_string body (String.sub lines.(!j) 4 (String.length lines.(!j) - 4));
        incr j
      done;
      let command =
        if Str.string_match (Str.regexp ".*<<") first 0 then first else Buffer.contents body
      in
      collect !j ((i + 1, command) :: acc))
    else collect (i + 1) acc
  in
  collect 0 []

let violations ~file text =
  commands text
  |> List.concat_map (fun (line, command) ->
      List.map (fun stage -> Printf.sprintf "%s:%d: %s" file line stage) (masked_upstreams command))

let cram_dir = "cli"

let test_no_masked_status () =
  let files =
    Sys.readdir cram_dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".t")
    |> List.sort String.compare
  in
  Alcotest.(check bool) "crams found" true (List.length files > 50);
  let found =
    List.concat_map
      (fun f ->
        violations ~file:("test/cli/" ^ f) (Corpus_support.read_file (Filename.concat cram_dir f)))
      files
  in
  Alcotest.(check (list string)) "no tool status hidden by a pipeline" [] found

let test_detector_cases () =
  let flagged cmd = masked_upstreams cmd <> [] in
  List.iter
    (fun cmd -> Alcotest.(check bool) ("flags: " ^ cmd) true (flagged cmd))
    [
      "jacquard run x.jac | head -1";
      "JACQUARD=jac sh \"$D/run.sh\" 2>&1 | sed -n '/^== Warp/,$p'";
      "(cd ../app && jacquard project test) | tail -1";
      "H=$(jacquard hash x.jac | grep ':f ' | cut -d' ' -f2)";
      "for f in a b; do jac check $f | wc -l; done";
      "test \"$(sh x.sh | wc -l)\" = 1";
      "timeout 60 jacquard run --fuel 9 x.jac 2>&1 | head -1";
      "echo 1 > d.jac && jacquard project run d 2>&1 | grep -A1 error";
      "../../scripts/native-leak-check.sh a.jqd 2>&1 | tail -1";
      "{ jac project hash; jac hash x.jac; } | cut -d' ' -f2";
      "./native-binary | cmp - expected.out";
    ];
  List.iter
    (fun cmd -> Alcotest.(check bool) ("accepts: " ^ cmd) false (flagged cmd))
    [
      "jacquard run x.jac > pipe.out 2>&1 || echo \"exit=$?\"; head -1 < pipe.out";
      "printf 'x\\n' | jacquard run - --allow console";
      "cat f | grep x | wc -l";
      "test \"$(sha256sum scripts/release/check.sh | awk '{print $1}')\" = abc";
      "grep 'jacquard|jac' notes.txt";
      "jacquard check x.jac || echo refused";
      "echo 'jacquard run | head' > note.txt";
      "echo \"${HOME}\" | wc -c";
    ]

let test_heredoc_body_is_data () =
  let text = "  $ cat > s.sh <<'EOF'\n  > jacquard run x | head -1\n  > EOF\n" in
  Alcotest.(check (list string)) "heredoc body ignored" [] (violations ~file:"t" text)

let suite =
  [
    Alcotest.test_case "no cram hides a tool's exit status" `Quick test_no_masked_status;
    Alcotest.test_case "masked-status detector" `Quick test_detector_cases;
    Alcotest.test_case "here-document bodies are data" `Quick test_heredoc_body_is_data;
  ]
