(* Cram transcripts record the exit status of a command line's last pipeline stage only. A
   Jacquard tool or script piped into an excerpting filter (`| sed`, `| head`, `| grep`) can
   therefore fail without changing the transcript: that is how a failing release-only demo suite
   once reached release evidence. This law finds every pipeline with a non-final stage that runs a
   tool or script; such commands write the output to a file, pin the status, then excerpt:

     jacquard run x.jac > pipe.out 2>&1 || echo "exit=$?"; head -1 < pipe.out

   The scanner is a small POSIX-shell lexer and parser: words lose their quotes, command
   substitutions (`$(...)` and backticks, with escaped backticks nested) and the scripts of
   `sh -c`/`bash -c` are scanned as nested scripts, a process substitution's status is never
   recorded so any tool inside one is flagged, here-document bodies are data (an unquoted body's
   substitutions are scanned), and subshells, brace groups and for/while/until/if/case compounds
   are pipeline stages like simple commands. A substitution as the command word counts as a tool.

   The pinned statuses are tested by scripts/dev/cram-status-mutation.py, which reruns a cram once
   per checked block with the `jacquard`/`jac` exit status shifted by 50 inside that block (see
   docs/ci-cd.md); it runs the crams, so it is a manual check rather than part of this suite. *)

type token = Word of string | Op of string

let shell_words = [ "sh"; "bash"; "dash" ]
let tool_words = [ "jacquard"; "jac" ] @ shell_words

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
let is_digit c = c >= '0' && c <= '9'

(* Options of a prefix word whose value is the next word (`--opt=value` is one word already). *)
let prefix_value_options = function
  | "timeout" -> [ "-s"; "--signal"; "-k"; "--kill-after" ]
  | "env" -> [ "-u"; "--unset"; "-C"; "--chdir" ]
  | "nice" -> [ "-n"; "--adjustment" ]
  | "exec" -> [ "-a" ]
  | "time" -> [ "-f"; "--format"; "-o"; "--output" ]
  | "xargs" ->
      [
        "-I";
        "-n";
        "-P";
        "-L";
        "-s";
        "-d";
        "-E";
        "-a";
        "--max-args";
        "--max-procs";
        "--max-lines";
        "--max-chars";
        "--delimiter";
        "--eof";
        "--arg-file";
        "--process-slot-var";
      ]
  | _ -> []

(* `env -S STRING` splits STRING into the command it runs: treated as a tool. In a short-option
   cluster, the text after `u` or `C` is that option's value (`-uSHELL`). *)
let env_split_string w =
  let n = String.length w in
  let rec cluster i =
    i < n && match w.[i] with 'S' -> true | 'u' | 'C' -> false | _ -> cluster (i + 1)
  in
  w = "--split-string"
  || String.starts_with ~prefix:"--split-string=" w
  || (n >= 2 && w.[0] = '-' && w.[1] <> '-' && cluster 1)

(* A `timeout`/`sleep`-style duration: a number with a digit, an optional fraction and an optional
   unit (`60`, `1.5s`, `.5`, `2m`). *)
let is_duration w =
  let n = String.length w in
  let body = if n > 1 && String.contains "smhd" w.[n - 1] then n - 1 else n in
  let number = String.sub w 0 (max 0 body) in
  String.exists is_digit number && String.for_all (fun c -> is_digit c || c = '.') number

(* [shell_script args] is the command string of `sh -c`: the first operand after the options when
   an option cluster contains `c`. Each `o`/`O` in a cluster (`-euo pipefail`) takes the next word
   as its value. *)
let shell_script args =
  let rec drop k l = match l with _ :: rest when k > 0 -> drop (k - 1) rest | _ -> l in
  let rec options c = function
    | ("--rcfile" | "--init-file") :: _ :: rest -> options c rest
    | "--" :: rest -> operand c rest
    | w :: rest when String.starts_with ~prefix:"--" w -> options c rest
    | w :: rest when String.length w > 1 && (w.[0] = '-' || w.[0] = '+') ->
        let values = ref 0 in
        String.iteri (fun i ch -> if i > 0 && (ch = 'o' || ch = 'O') then incr values) w;
        options (c || (w.[0] = '-' && String.contains w 'c')) (drop !values rest)
    | rest -> operand c rest
  and operand c = function w :: _ when c -> Some w | _ -> None in
  options false args

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

(* [close_backtick s i] is the index of the backtick closing one opened before [i], skipping
   backslash escapes, or the length of [s] when there is none. *)
let close_backtick s i =
  let n = String.length s in
  let rec go i =
    if i >= n then n else if s.[i] = '\\' then go (i + 2) else if s.[i] = '`' then i else go (i + 1)
  in
  go i

(* The script of a backtick substitution: [\`], [\\] and [\$] lose their backslash. *)
let unescape_backticks t =
  let n = String.length t in
  let b = Buffer.create n in
  let rec go i =
    if i < n then
      if t.[i] = '\\' && i + 1 < n && (t.[i + 1] = '`' || t.[i + 1] = '\\' || t.[i + 1] = '$') then (
        Buffer.add_char b t.[i + 1];
        go (i + 2))
      else (
        Buffer.add_char b t.[i];
        go (i + 1))
  in
  go 0;
  Buffer.contents b

(* [analyze script found] scans one shell script, adding to [found] the text of every pipeline
   stage that runs a tool and is not the pipeline's last stage; it returns whether a tool runs
   anywhere in the script. *)
let rec analyze script (found : string list ref) =
  let tokens = lex script found in
  (* at top level a stray `)` or `;;` ends a list early; resume after it *)
  let rec from i any =
    let j, tool = parse_list tokens i [] [ ")"; ";;" ] found in
    if j < Array.length tokens then from (j + 1) (any || tool) else any || tool
  in
  from 0 false

(* [substitution s i found] scans the substitution starting at [s.[i]] (`$(`, `$((` or a
   backtick), analyzing a command substitution's script, and returns the index after it with its
   stand-in word text: `$(X)` for a command substitution, so that one used as a command word is a
   tool, and `X` for arithmetic. `$((` is arithmetic only when the inner parenthesis closes right
   before the outer one; otherwise it is a command substitution of a script starting with a
   subshell, as in `$((jac run x) | head -1)`. *)
and substitution s i found =
  let n = String.length s in
  if s.[i] = '`' then (
    let j = close_backtick s (i + 1) in
    ignore (analyze (unescape_backticks (String.sub s (i + 1) (max 0 (j - i - 1)))) found);
    (min n (j + 1), "$(X)"))
  else
    let inner = if i + 2 < n && s.[i + 2] = '(' then close_paren s (i + 3) else n in
    if inner < n && s.[inner] = ')' then (inner + 1, "X")
    else
      let j = close_paren s (i + 2) in
      ignore (analyze (String.sub s (i + 2) (max 0 (j - i - 3))) found);
      (j, "$(X)")

and lex s found =
  let n = String.length s in
  let toks = ref [] in
  let word = Buffer.create 32 in
  let in_word = ref false in
  let heredocs = ref [] in
  (* a redirection or here-string target is lexed like any word (its substitutions are
     scanned) and then dropped. [drop] is set by a redirection or here-string operator (not by
     `>&N`, whose descriptor is skipped) and cleared when the next word, its target, is flushed
     and discarded; a newline or control operator also clears it, so a target-less redirection
     cannot swallow the next command's word. *)
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
  let rec skip_quote i q =
    if i >= n then n
    else if s.[i] = '\\' && q = '"' then skip_quote (i + 2) q
    else if s.[i] = q then i + 1
    else skip_quote (i + 1) q
  in
  let subst i =
    let j, stand_in = substitution s i found in
    add_s stand_in;
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
      | '$' when i + 1 < n && s.[i + 1] = '(' -> double (subst i)
      | '`' -> double (subst i)
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
        else if body.[i] = '`' || (body.[i] = '$' && i + 1 < m && body.[i + 1] = '(') then
          go (fst (substitution body i found))
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
      | '`' -> go (subst i)
      | '$' when i + 1 < n && s.[i + 1] = '(' -> go (subst i)
      | ('<' | '>') when i + 1 < n && s.[i + 1] = '(' ->
          (* a process substitution: its status is never recorded, so a tool inside is flagged *)
          let j = close_paren s (i + 2) in
          if analyze (String.sub s (i + 2) (max 0 (j - i - 3))) found then
            found := String.sub s i (j - i) :: !found;
          add 'X';
          go j
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
            if !j < n && s.[!j - 1] = '&' && (is_digit s.[!j] || s.[!j] = '-') then (
              (* `>&N`, `>&N-`, `>&-`: a descriptor, not a target word *)
              let k = ref !j in
              while !k < n && is_digit s.[!k] do
                incr k
              done;
              if !k < n && s.[!k] = '-' then incr k;
              go !k)
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
      (* `;;&` and `;&` end a case item like `;;` *)
      | ';' when i + 2 < n && s.[i + 1] = ';' && s.[i + 2] = '&' -> op ";;" (i + 3)
      | ';' when i + 1 < n && (s.[i + 1] = ';' || s.[i + 1] = '&') -> op ";;" (i + 2)
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
   reserved words that end the current list at command position; [closers] are the operators that
   end it (`)` for a subshell, `;;` for a case item). Any other `)` or `;;` is stray and skipped
   like a separator, so a brace group, loop or if body continues to its own terminator. *)
and parse_list toks i stops closers found =
  let n = Array.length toks in
  let rec go i any =
    if i >= n then (i, any)
    else
      match toks.(i) with
      | Op o when List.mem o closers -> (i, any)
      | Op ("\n" | ";" | "&" | "&&" | "||" | ")" | ";;") -> go (i + 1) any
      | Word w when List.mem w stops -> (i, any)
      | _ ->
          let j, tool = parse_pipeline toks i stops found in
          if j = i then go (i + 1) any else go j (any || tool)
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
        let k, tool = parse_list toks (j + 1) [] [ ")" ] found in
        Some ((if k < n && toks.(k) = Op ")" then k + 1 else k), tool)
    | Word "{" ->
        let k, tool = parse_list toks (j + 1) [ "}" ] [] found in
        Some (expect k "}", tool)
    | Word ("for" | "select") ->
        let k = skip_to j "do" in
        let k, tool = parse_list toks k [ "done" ] [] found in
        Some (expect k "done", tool)
    | Word ("while" | "until") ->
        let k, t1 = parse_list toks (j + 1) [ "do" ] [] found in
        let k, t2 = parse_list toks (expect k "do") [ "done" ] [] found in
        Some (expect k "done", t1 || t2)
    | Word "if" ->
        let rec arms k tool =
          let k, t1 = parse_list toks k [ "then" ] [] found in
          let k, t2 = parse_list toks (expect k "then") [ "elif"; "else"; "fi" ] [] found in
          let tool = tool || t1 || t2 in
          if k < n && toks.(k) = Word "elif" then arms (k + 1) tool
          else if k < n && toks.(k) = Word "else" then
            let k, t3 = parse_list toks (k + 1) [ "fi" ] [] found in
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
            let k, t = parse_list toks (min n (!k + 1)) [ "esac" ] [ ";;" ] found in
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
      let words =
        Array.sub toks start (!j - start)
        |> Array.to_list
        |> List.filter_map (function Word w -> Some w | Op _ -> None)
      in
      (* the command word and its arguments; [`Opaque] runs a command we cannot see *)
      let rec command_word = function
        | w :: rest when is_assignment w -> command_word rest
        | w :: rest when List.mem w prefix_words -> after_prefix w rest
        | w :: rest -> `Command (w, rest)
        | [] -> `None
      and after_prefix prefix = function
        | w :: _ when prefix = "env" && env_split_string w -> `Opaque
        | w :: _ :: rest when List.mem w (prefix_value_options prefix) -> after_prefix prefix rest
        | w :: rest when String.starts_with ~prefix:"-" w || is_duration w ->
            after_prefix prefix rest
        | rest -> command_word rest
      in
      let tool =
        match command_word words with
        | `Command (w, args) ->
            (if List.mem (Filename.basename w) shell_words then
               match shell_script args with
               | Some script -> ignore (analyze script found)
               | None -> ());
            is_tool w
        | `Opaque -> true
        | `None -> false
      in
      (!j, tool, text i !j)

let masked_upstreams script =
  let found = ref [] in
  ignore (analyze script found);
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
      (* sh -c / bash -c scripts *)
      "sh -c 'jac run x | head -1'";
      "bash -ec \"jac run x | head -1\"";
      "sh -o pipefail -c 'echo \"$(jac hash x | head -1)\"'";
      "timeout 60 sh -c 'jac run x | head -1'";
      (* wrapper options with values *)
      "timeout -s KILL 60 jacquard run x | head -1";
      "timeout --kill-after 5 60 jac run x | head -1";
      "env -u HOME jac run x | head -1";
      "env -C ../app jac project run demo | head -1";
      "env -S 'jac run x' | head -1";
      "nice -n 5 jac run x | head -1";
      "xargs -I {} jac run {} < list | head -1";
      "time -f %e jac run x | head -1";
      (* a substitution as the command word *)
      "$(which jac) run x | head -1";
      "`which jac` run x | head -1";
      (* process substitution, rarer operators, escaped backticks, `$((` *)
      "diff <(jac run x) expected.out";
      "while read l; do echo $l; done < <(jac run x)";
      "cat f > >(jac run -)";
      "jac run x 1<>f | head -1";
      "case $x in a) echo ;& b) jac run x | head -1 ;;& esac";
      "echo `echo \\`jac hash x | head -1\\``";
      "cat <<EOF\nit's `jac hash x | head -1`\nEOF";
      "echo $((jac run x) | head -1)";
      (* stray `)` / `;;` inside compounds *)
      "{ echo ); jac run x; } | head -1";
      "for f in a; do echo ;; jac run x; done | head -1";
      "if true; then echo ); jac run x; fi | head -1";
      (* descriptor duplication *)
      "2>&10 jac run x | head -1";
      "2>&- jac run x | head -1";
      "jac run x > 2 2>&1 | wc -c";
      "timeout 1m jac run x | head -1";
      "timeout .5 jac run x | head -1";
      "bash --rcfile f -c 'jac run x | head -1'";
      "case $x in a) echo ;;& esac; jac run x | head -1";
      "bash -euo pipefail -c 'jac run x | head -1'";
      "bash -ceo pipefail 'jac run x | head -1'";
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
      "sh -c 'echo x | head -1'";
      "bash -euo pipefail -c 'echo x | head -1'";
      "timeout -s KILL 60 cat f | head -1";
      "xargs -n 1 echo < list | head -1";
      "H=$(jac hash x) && echo \"$H\" | wc -c";
      "diff <(sort a) <(sort b)";
      "cat 0<>f | wc -l";
      "case $x in a) echo ;& b) echo ;;& esac";
      "echo $(( (1 + 2) * 3 )) | wc -c";
      "echo x > 2 2>&1 | wc -c";
      "echo x 2>&10 | wc -c";
      "env -uSHELL echo x | head -1";
      "timeout 1m cat f | head -1";
    ]

let suite =
  [
    Alcotest.test_case "no cram hides a tool's exit status" `Quick test_no_masked_status;
    Alcotest.test_case "masked-status detector" `Quick test_detector_cases;
  ]
