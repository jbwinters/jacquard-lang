(* Cram transcripts record the exit status of a command line's last pipeline stage only. A
   Jacquard tool or script piped into an excerpting filter (`| sed`, `| head`, `| grep`) can
   therefore fail without changing the transcript: that is how a failing release-only demo suite
   once reached release evidence. This law finds every pipeline with a non-final stage that runs a
   tool or script; such commands write the output to a file, pin the status, then excerpt:

     jacquard run x.jac > pipe.out 2>&1 || echo "exit=$?"; head -1 < pipe.out

   The scanner is a small POSIX-shell lexer and parser: words lose their quotes, command and
   arithmetic substitutions are scanned as nested scripts, here-document bodies are data (an
   unquoted body's substitutions are scanned), and subshells, brace groups and
   for/while/until/if/case compounds are pipeline stages like simple commands. *)

type token = Word of string | Op of string

let tool_words = [ "jacquard"; "jac"; "sh"; "bash"; "dash" ]

let filter_words =
  [
    "awk";
    "cat";
    "cmp";
    "cut";
    "diff";
    "echo";
    "grep";
    "head";
    "ls";
    "od";
    "printf";
    "sed";
    "sort";
    "tail";
    "tee";
    "test";
    "tr";
    "uniq";
    "wc";
    "xxd";
  ]

(* Words that run the command they prefix; options and numbers after them are skipped too. *)
let prefix_words = [ "!"; "command"; "env"; "exec"; "nice"; "nohup"; "time"; "timeout"; "xargs" ]

let is_tool word =
  let base = Filename.basename word in
  List.mem base tool_words || Filename.check_suffix word ".sh" || Filename.check_suffix word ".exe"
  || String.starts_with ~prefix:"$" word
  || (String.contains word '/' && not (List.mem base filter_words))

let is_assignment word =
  match String.index_opt word '=' with
  | Some i when i > 0 ->
      String.for_all
        (fun c ->
          c = '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
        (String.sub word 0 i)
  | _ -> false

(* [close_paren s i] is the index just past the `)` closing a group opened before [i], skipping
   quoted text and escapes and counting nested parentheses. *)
let close_paren s i =
  let n = String.length s in
  let rec quote i q =
    if i >= n then n
    else if s.[i] = '\\' && q = '"' then quote (i + 2) q
    else if s.[i] = q then i + 1
    else quote (i + 1) q
  in
  let rec go i depth =
    if i >= n then n
    else
      match s.[i] with
      | '\\' -> go (i + 2) depth
      | ('\'' | '"') as q -> go (quote (i + 1) q) depth
      | '(' -> go (i + 1) (depth + 1)
      | ')' -> if depth = 1 then i + 1 else go (i + 1) (depth - 1)
      | _ -> go (i + 1) depth
  in
  go i 1

(* [analyze script found] scans one shell script, adding to [found] the text of every pipeline
   stage that runs a tool and is not the pipeline's last stage. *)
let rec analyze script (found : string list ref) =
  let tokens = lex script found in
  (* a stray `)`, `;;` or reserved word ends a list early; resume after it *)
  let rec from i =
    let j, _ = parse_list tokens i [] found in
    if j < Array.length tokens then from (j + 1)
  in
  from 0

and lex s found =
  let n = String.length s in
  let toks = ref [] in
  let word = Buffer.create 32 in
  let in_word = ref false in
  let heredocs = ref [] in
  (* a redirection or here-string target is lexed like any word (its substitutions are
     scanned) and then dropped *)
  let drop = ref false in
  let flush () =
    if !in_word then if !drop then drop := false else toks := Word (Buffer.contents word) :: !toks;
    Buffer.clear word;
    in_word := false
  in
  let add c =
    Buffer.add_char word c;
    in_word := true
  in
  let add_s str =
    Buffer.add_string word str;
    in_word := true
  in
  (* index just past the [close] matching an [open_] at depth 1, skipping quotes *)
  let rec matching i open_ close depth =
    if i >= n then n
    else if s.[i] = '\\' then matching (i + 2) open_ close depth
    else if s.[i] = '\'' then matching (skip_quote (i + 1) '\'') open_ close depth
    else if s.[i] = '"' then matching (skip_quote (i + 1) '"') open_ close depth
    else if s.[i] = close then if depth = 1 then i + 1 else matching (i + 1) open_ close (depth - 1)
    else if s.[i] = open_ then matching (i + 1) open_ close (depth + 1)
    else matching (i + 1) open_ close depth
  and skip_quote i q =
    if i >= n then n
    else if s.[i] = '\\' && q = '"' then skip_quote (i + 2) q
    else if s.[i] = q then i + 1
    else skip_quote (i + 1) q
  in
  let substitution i =
    (* at "$(" or "`": scan the nested script, return the index after it *)
    if s.[i] = '`' then (
      let j = match String.index_from_opt s (i + 1) '`' with Some j -> j | None -> n in
      analyze (String.sub s (i + 1) (max 0 (j - i - 1))) found;
      add 'X';
      min n (j + 1))
    else if i + 2 < n && s.[i + 2] = '(' then (
      let j = matching (i + 3) '(' ')' 2 in
      add 'X';
      j)
    else
      let j = matching (i + 2) '(' ')' 1 in
      analyze (String.sub s (i + 2) (max 0 (j - i - 3))) found;
      add 'X';
      j
  in
  let rec double i =
    if i >= n then n
    else
      match s.[i] with
      | '"' -> i + 1
      | '\\' when i + 1 < n ->
          add s.[i + 1];
          double (i + 2)
      | '$' when i + 1 < n && s.[i + 1] = '(' -> double (substitution i)
      | '`' -> double (substitution i)
      | c ->
          add c;
          double (i + 1)
  in
  let read_word_at i =
    (* the next word after optional blanks, as (text, quoted, next index); used for redirection
       targets and here-document delimiters *)
    let i = ref i in
    while !i < n && (s.[!i] = ' ' || s.[!i] = '\t') do
      incr i
    done;
    let buf = Buffer.create 16 and quoted = ref false in
    let stop = ref false in
    while (not !stop) && !i < n do
      match s.[!i] with
      | ' ' | '\t' | '\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>' -> stop := true
      | ('\'' | '"') as q ->
          quoted := true;
          let j = skip_quote (!i + 1) q in
          Buffer.add_string buf (String.sub s (!i + 1) (max 0 (j - !i - 2)));
          i := j
      | '\\' ->
          quoted := true;
          if !i + 1 < n then Buffer.add_char buf s.[!i + 1];
          i := !i + 2
      | c ->
          Buffer.add_char buf c;
          incr i
    done;
    (Buffer.contents buf, !quoted, !i)
  in
  let scan_body body =
    (* unquoted here-document body: only its substitutions are code *)
    let m = String.length body in
    let rec go i =
      if i < m then
        if body.[i] = '\\' then go (i + 2)
        else if body.[i] = '`' || (body.[i] = '$' && i + 1 < m && body.[i + 1] = '(') then (
          let sub = String.sub body i (m - i) in
          let consumed = ref 0 in
          (* reuse the lexer's substitution scanner on the remaining text *)
          let sub_found = ref [] in
          (if sub.[0] = '`' then
             match String.index_from_opt sub 1 '`' with
             | Some j ->
                 analyze (String.sub sub 1 (j - 1)) sub_found;
                 consumed := j + 1
             | None -> consumed := String.length sub
           else
             let j = close_paren sub 2 in
             analyze (String.sub sub 2 (max 0 (j - 3))) sub_found;
             consumed := j);
          found := !sub_found @ !found;
          go (i + max 1 !consumed))
        else go (i + 1)
    in
    go 0
  in
  let rec go i =
    if i < n then
      match s.[i] with
      | ' ' | '\t' ->
          flush ();
          go (i + 1)
      | '\\' when i + 1 < n && s.[i + 1] = '\n' -> go (i + 2)
      | '\\' when i + 1 < n ->
          add s.[i + 1];
          go (i + 2)
      | '#' when not !in_word ->
          let j = match String.index_from_opt s i '\n' with Some j -> j | None -> n in
          go j
      | '\n' ->
          flush ();
          drop := false;
          toks := Op "\n" :: !toks;
          let j = ref (i + 1) in
          List.iter
            (fun (delim, quoted, strip_tabs) ->
              let body = Buffer.create 64 and fin = ref false in
              while (not !fin) && !j < n do
                let e = match String.index_from_opt s !j '\n' with Some e -> e | None -> n in
                let line = String.sub s !j (e - !j) in
                let cmp =
                  if strip_tabs then (
                    let k = ref 0 in
                    while !k < String.length line && line.[!k] = '\t' do
                      incr k
                    done;
                    String.sub line !k (String.length line - !k))
                  else line
                in
                j := min n (e + 1);
                if String.equal cmp delim then fin := true
                else (
                  Buffer.add_string body line;
                  Buffer.add_char body '\n')
              done;
              if not quoted then scan_body (Buffer.contents body))
            (List.rev !heredocs);
          heredocs := [];
          go !j
      | '\'' ->
          let j = skip_quote (i + 1) '\'' in
          add_s (String.sub s (i + 1) (max 0 (j - i - 2)));
          go j
      | '"' ->
          in_word := true;
          go (double (i + 1))
      | '`' -> go (substitution i)
      | '$' when i + 1 < n && s.[i + 1] = '(' -> go (substitution i)
      | ('<' | '>') as c ->
          (* a redirection: drop a leading fd number and the target word *)
          if
            !in_word && (not !drop)
            && String.for_all (fun c -> c >= '0' && c <= '9') (Buffer.contents word)
          then (
            Buffer.clear word;
            in_word := false)
          else flush ();
          if c = '<' && i + 2 < n && s.[i + 1] = '<' && s.[i + 2] = '<' then (
            drop := true;
            go (i + 3))
          else if c = '<' && i + 1 < n && s.[i + 1] = '<' then (
            let strip_tabs = i + 2 < n && s.[i + 2] = '-' in
            let delim, quoted, j = read_word_at (if strip_tabs then i + 3 else i + 2) in
            heredocs := (delim, quoted, strip_tabs) :: !heredocs;
            go j)
          else
            let j = ref (i + 1) in
            while !j < n && (s.[!j] = '>' || s.[!j] = '&' || s.[!j] = '|') do
              incr j
            done;
            if !j < n && s.[!j - 1] = '&' && s.[!j] >= '0' && s.[!j] <= '9' then go (!j + 1)
            else (
              drop := true;
              go !j)
      | '|' when i + 1 < n && s.[i + 1] = '|' -> op "||" (i + 2)
      | '|' when i + 1 < n && s.[i + 1] = '&' -> op "|" (i + 2)
      | '|' -> op "|" (i + 1)
      | '&' when i + 1 < n && s.[i + 1] = '&' -> op "&&" (i + 2)
      | '&' when i + 1 < n && s.[i + 1] = '>' ->
          flush ();
          drop := true;
          go (i + 2)
      | ';' when i + 1 < n && s.[i + 1] = ';' -> op ";;" (i + 2)
      | (';' | '&' | '(' | ')') as c -> op (String.make 1 c) (i + 1)
      | c ->
          add c;
          go (i + 1)
  and op o i =
    flush ();
    drop := false;
    toks := Op o :: !toks;
    go i
  in
  go 0;
  flush ();
  Array.of_list (List.rev !toks)

(* Parsing returns (next index, whether a tool runs anywhere in the parsed text). [stops] are
   reserved words that end the current list at command position. *)
and parse_list toks i stops found =
  let n = Array.length toks in
  let rec go i any =
    if i >= n then (i, any)
    else
      match toks.(i) with
      | Op ("\n" | ";" | "&" | "&&" | "||") -> go (i + 1) any
      | Op (")" | ";;") -> (i, any)
      | Word w when List.mem w stops -> (i, any)
      | _ ->
          let j, tool = parse_pipeline toks i stops found in
          if j = i then (i + 1, any) else go j (any || tool)
  in
  go i false

and parse_pipeline toks i stops found =
  let n = Array.length toks in
  let rec go i stages =
    let j, tool, text = parse_stage toks i stops found in
    let stages = (tool, text) :: stages in
    if j < n && toks.(j) = Op "|" then go (j + 1) stages else (j, stages)
  in
  let j, stages = go i [] in
  (match stages with
  | _last :: upstream ->
      List.iter (fun (tool, text) -> if tool then found := text :: !found) (List.rev upstream)
  | [] -> ());
  (j, List.exists fst stages)

and parse_stage toks i stops found =
  let n = Array.length toks in
  let text a b =
    let a = min a n and b = min b n in
    Array.sub toks a (max 0 (b - a))
    |> Array.to_list
    |> List.map (function Word w -> w | Op o -> if o = "\n" then ";" else o)
    |> String.concat " "
  in
  let expect j w = if j < n && toks.(j) = Word w then j + 1 else j in
  let skip_to j w =
    let j = ref j in
    while !j < n && toks.(!j) <> Word w do
      incr j
    done;
    expect !j w
  in
  let compound j =
    match if j < n then toks.(j) else Op "" with
    | Op "(" ->
        let k, tool = parse_list toks (j + 1) [] found in
        Some ((if k < n && toks.(k) = Op ")" then k + 1 else k), tool)
    | Word "{" ->
        let k, tool = parse_list toks (j + 1) [ "}" ] found in
        Some (expect k "}", tool)
    | Word ("for" | "select") ->
        let k = skip_to j "do" in
        let k, tool = parse_list toks k [ "done" ] found in
        Some (expect k "done", tool)
    | Word ("while" | "until") ->
        let k, t1 = parse_list toks (j + 1) [ "do" ] found in
        let k, t2 = parse_list toks (expect k "do") [ "done" ] found in
        Some (expect k "done", t1 || t2)
    | Word "if" ->
        let rec arms k tool =
          let k, t1 = parse_list toks k [ "then" ] found in
          let k, t2 = parse_list toks (expect k "then") [ "elif"; "else"; "fi" ] found in
          let tool = tool || t1 || t2 in
          if k < n && toks.(k) = Word "elif" then arms (k + 1) tool
          else if k < n && toks.(k) = Word "else" then
            let k, t3 = parse_list toks (k + 1) [ "fi" ] found in
            (expect k "fi", tool || t3)
          else (expect k "fi", tool)
        in
        Some (arms (j + 1) false)
    | Word "case" ->
        let k = skip_to j "in" in
        let rec items k tool =
          let k = ref k in
          while !k < n && (toks.(!k) = Op "\n" || toks.(!k) = Op ";") do
            incr k
          done;
          let k = !k in
          if k >= n || toks.(k) = Word "esac" then (expect k "esac", tool)
          else
            (* a pattern list up to ")" then a list up to ";;" or "esac" *)
            let k = ref k in
            while !k < n && toks.(!k) <> Op ")" do
              incr k
            done;
            let k, t = parse_list toks (min n (!k + 1)) [ "esac" ] found in
            let k = if k < n && toks.(k) = Op ";;" then k + 1 else k in
            items k (tool || t)
        in
        Some (items k false)
    | _ -> None
  in
  let rec skip_bang j = if j < n && toks.(j) = Word "!" then skip_bang (j + 1) else j in
  let start = skip_bang i in
  match compound start with
  | Some (j, tool) -> (j, tool, text i j)
  | None ->
      let j = ref start in
      while
        !j < n
        && match toks.(!j) with Word w -> not (!j = start && List.mem w stops) | Op _ -> false
      do
        incr j
      done;
      let words = Array.sub toks start (!j - start) |> Array.to_list in
      let rec command_word = function
        | Word w :: rest when is_assignment w -> command_word rest
        | Word w :: rest when List.mem w prefix_words -> after_prefix rest
        | Word w :: _ -> Some w
        | _ -> None
      and after_prefix = function
        | Word w :: rest
          when String.starts_with ~prefix:"-" w
               || w <> ""
                  && String.for_all (fun c -> (c >= '0' && c <= '9') || c = '.' || c = 's') w ->
            after_prefix rest
        | rest -> command_word rest
      in
      let tool = match command_word words with Some w -> is_tool w | None -> false in
      (!j, tool, text i !j)

let masked_upstreams script =
  let found = ref [] in
  analyze script found;
  List.rev !found

(* Commands of a cram transcript: each `  $ ` line with its `  > ` continuations. *)
let commands text =
  let lines = String.split_on_char '\n' text |> Array.of_list in
  let count = Array.length lines in
  let strip l = String.sub l 4 (String.length l - 4) in
  let rec collect i acc =
    if i >= count then List.rev acc
    else if String.starts_with ~prefix:"  $ " lines.(i) then (
      let body = Buffer.create 80 in
      Buffer.add_string body (strip lines.(i));
      let j = ref (i + 1) in
      while !j < count && String.starts_with ~prefix:"  > " lines.(!j) do
        Buffer.add_char body '\n';
        Buffer.add_string body (strip lines.(!j));
        incr j
      done;
      collect !j ((i + 1, Buffer.contents body ^ "\n") :: acc))
    else collect (i + 1) acc
  in
  collect 0 []

let violations ~file text =
  commands text
  |> List.concat_map (fun (line, command) ->
      List.map (fun stage -> Printf.sprintf "%s:%d: %s" file line stage) (masked_upstreams command))

(* Every regular `.t` file under the test directory (the working directory of the suite, staged by
   the `(glob_files_rec *.t)` dependency); dune's `.cram.*` work directories are skipped. *)
let rec cram_files dir =
  Sys.readdir dir |> Array.to_list |> List.sort String.compare
  |> List.concat_map (fun entry ->
      let path = if dir = "." then entry else Filename.concat dir entry in
      if String.starts_with ~prefix:"." entry || entry = "_build" then []
      else if Sys.is_directory path then cram_files path
      else if Filename.check_suffix entry ".t" then [ path ]
      else [])

let test_no_masked_status () =
  let files = cram_files "." in
  Alcotest.(check bool) "crams found" true (List.length files > 50);
  let found =
    List.concat_map (fun f -> violations ~file:("test/" ^ f) (Corpus_support.read_file f)) files
  in
  Alcotest.(check (list string)) "no tool status hidden by a pipeline" [] found

let test_detector_cases () =
  let flagged cmd = masked_upstreams (cmd ^ "\n") <> [] in
  List.iter
    (fun cmd -> Alcotest.(check bool) ("flags: " ^ cmd) true (flagged cmd))
    [
      "jacquard run x.jac | head -1";
      "JACQUARD=jac sh \"$D/run.sh\" 2>&1 | sed -n '/^== Warp/,$p'";
      "JACQUARD=\"jac\" sh \"$D/run.sh\" | head -1";
      "\"$D/run.sh\" | sed 1q";
      "\"$JACQUARD\" run x.jac | head";
      "../x/jacquard run | head";
      "(cd ../app && jacquard project test) | tail -1";
      "H=$(jacquard hash x.jac | grep ':f ' | cut -d' ' -f2)";
      "test \"$(sh x.sh | wc -l)\" = 1";
      "N=`jac hash x | wc -l`";
      "for f in a b; do jac check $f | wc -l; done";
      "for f in a b; do jac check \"$f\"; done | head -1";
      "while read f; do jac check $f; done < list | tail -1";
      "if jacquard check x | grep -q E; then echo bad; fi";
      "{ jac project hash; jac hash x.jac; } | cut -d' ' -f2";
      "timeout 60 jacquard run --fuel 9 x.jac 2>&1 | head -1";
      "echo 1 > d.jac && jacquard project run d 2>&1 | grep -A1 error";
      "../../scripts/native-leak-check.sh a.jqd 2>&1 | tail -1";
      "./native-binary | cmp - expected.out";
      "jacquard run x |& head -1";
      "cat <<'EOF' > /dev/null\nfixture\nEOF\njacquard run x.jac | head -1";
      "cat <<EOF > s.txt\n$(jac hash x | head -1)\nEOF";
      "case $x in a) jac run x | head -1 ;; esac";
      "case $x in a) echo ;;\nesac\njac run x | head -1";
      "echo ) ; jac run x | head -1";
      ": > \"$(jac hash x | head -1)\"";
      "cat <<<\"$(jac hash x | head -1)\"";
      "cat <<EOF\n$(printf ')'; jac run x | head -1)\nEOF";
      ": >\"1\">&2\njac run x | head -1";
      ">\"1\">&2 jac run x | head -1";
      ": >\njac run x | head -1";
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
      "cat > s.sh <<'EOF'\njacquard run x | head -1\nEOF";
      "echo $((1<<2)) | wc -c";
      "for f in a b; do echo $f; done | head -1";
    ]

let suite =
  [
    Alcotest.test_case "no cram hides a tool's exit status" `Quick test_no_masked_status;
    Alcotest.test_case "masked-status detector" `Quick test_detector_cases;
  ]
