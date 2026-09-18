(* [Check] and [Run] drive the interpreter; [Build] compiles the fixture natively into the scratch
   directory and runs the binary with the same grants and input, so a documented native claim is
   executed rather than asserted; [Commands] runs a copyable shell snippet (a `.sh` fixture) in a
   fresh scratch directory with `jacquard` on the PATH, so setup, build, and test instructions are
   checked against the current toolchain (APP.10). *)
type mode = Check | Run | Build | Commands

type example = {
  name : string;
  mode : mode;
  fixture : string;
  stdin : string option;  (** an artifact fed to the program's standard input, if any *)
  stdout : string option;
  stderr : string option;
  expected_exit : int;
  grants : string list;
  doc : string;
  line : int;
  source : string;
}

let failf fmt = Printf.ksprintf failwith fmt

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel contents)

let contains text needle =
  let rec loop index =
    index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || loop (index + 1))
  in
  needle = "" || loop 0

let audit_tutorial_commands doc =
  let contents = read_file doc in
  let setup =
    "Development-checkout commands assume the repo root and use\n`dune exec jacquard --`."
  in
  if not (contains contents setup) then
    failf "%s: development command setup must define `dune exec jacquard --`" doc;
  contents |> String.split_on_char '\n'
  |> List.filter (fun line -> not (String.starts_with ~prefix:"```jacquard" line))
  |> List.iter (fun line ->
      List.iter
        (fun command ->
          if contains line command then
            failf "%s: public command %S bypasses the development-checkout Dune command" doc command)
        [ "$ jac "; "$ jacquard "; "`jac "; "`jacquard " ])

let valid_name name =
  name <> "" && String.for_all (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false) name

let valid_artifact name =
  name <> ""
  && Filename.basename name = name
  && String.for_all (function 'a' .. 'z' | '0' .. '9' | '-' | '.' -> true | _ -> false) name

let split_once value separator =
  match String.index_opt value separator with
  | None -> None
  | Some index ->
      Some (String.sub value 0 index, String.sub value (index + 1) (String.length value - index - 1))

let parse_info ~doc ~line info =
  let tokens = String.split_on_char ' ' info |> List.filter (( <> ) "") in
  let fields = Hashtbl.create 8 in
  let allowed = [ "doctest"; "mode"; "fixture"; "stdin"; "stdout"; "stderr"; "exit"; "grants" ] in
  let add_field token =
    match split_once token '=' with
    | None -> failf "%s:%d: malformed doctest field %S (expected key=value)" doc line token
    | Some (key, _) when not (List.mem key allowed) ->
        failf "%s:%d: unknown doctest field %S" doc line key
    | Some (key, _) when Hashtbl.mem fields key ->
        failf "%s:%d: duplicate doctest field %S" doc line key
    | Some (key, value) -> Hashtbl.add fields key value
  in
  (match tokens with
  | ("```jacquard" | "```sh") :: rest -> List.iter add_field rest
  | _ -> failf "%s:%d: malformed executable Jacquard fence" doc line);
  let shell_fence = List.hd tokens = "```sh" in
  let required key =
    match Hashtbl.find_opt fields key with
    | Some value when value <> "" -> value
    | _ -> failf "%s:%d: missing doctest field %S" doc line key
  in
  let name = required "doctest" in
  if not (valid_name name) then failf "%s:%d: invalid doctest name %S" doc line name;
  let mode =
    match required "mode" with
    | "check" -> Check
    | "run" -> Run
    | "build" -> Build
    | "commands" -> Commands
    | value -> failf "%s:%d: unknown doctest mode %S" doc line value
  in
  if shell_fence <> (mode = Commands) then
    failf "%s:%d: a `sh` fence needs mode=commands and a `jacquard` fence needs a Jacquard mode" doc
      line;
  let fixture = required "fixture" in
  let fixture_suffix = if mode = Commands then ".sh" else ".jac" in
  if not (valid_artifact fixture && Filename.check_suffix fixture fixture_suffix) then
    failf "%s:%d: invalid doctest fixture %S" doc line fixture;
  let expectation key =
    match required key with
    | "empty" -> None
    | artifact when valid_artifact artifact -> Some artifact
    | artifact -> failf "%s:%d: invalid %s expectation %S" doc line key artifact
  in
  let stdin =
    match Hashtbl.find_opt fields "stdin" with
    | None | Some "" -> None
    | Some artifact when valid_artifact artifact && Filename.check_suffix artifact ".stdin" ->
        if mode = Check then failf "%s:%d: a check doctest takes no stdin" doc line;
        Some artifact
    | Some artifact -> failf "%s:%d: invalid stdin artifact %S" doc line artifact
  in
  let expected_exit =
    match int_of_string_opt (required "exit") with
    | Some code when code >= 0 && code <= 255 -> code
    | _ -> failf "%s:%d: doctest exit must be an integer from 0 through 255" doc line
  in
  let grants =
    match Hashtbl.find_opt fields "grants" with
    | None | Some "" -> []
    | Some value ->
        let values = String.split_on_char ',' value in
        if List.exists (fun grant -> grant = "" || not (valid_name grant)) values then
          failf "%s:%d: invalid doctest grants %S" doc line value;
        values
  in
  if mode = Commands && grants <> [] then
    failf "%s:%d: a commands doctest states its grants in its own commands" doc line;
  {
    name;
    mode;
    fixture;
    stdin;
    stdout = expectation "stdout";
    stderr = expectation "stderr";
    expected_exit;
    grants;
    doc;
    line;
    source = "";
  }

let extract doc =
  let channel = open_in_bin doc in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
      let rec outside line examples =
        match input_line channel with
        | text
          when String.starts_with ~prefix:"```jacquard" text
               || String.starts_with ~prefix:"```sh doctest=" text ->
            let example = parse_info ~doc ~line text in
            inside (line + 1) line example (Buffer.create 256) examples
        | _ -> outside (line + 1) examples
        | exception End_of_file -> List.rev examples
      and inside line opening_line example source examples =
        match input_line channel with
        | "```" -> outside (line + 1) ({ example with source = Buffer.contents source } :: examples)
        | text ->
            Buffer.add_string source text;
            Buffer.add_char source '\n';
            inside (line + 1) opening_line example source examples
        | exception End_of_file -> failf "%s:%d: unterminated Jacquard doctest" doc opening_line
      in
      outside 1 [])

let artifact_names fixture_dir =
  Sys.readdir fixture_dir |> Array.to_list
  |> List.filter (fun name ->
      Filename.check_suffix name ".jac" || Filename.check_suffix name ".sh"
      || Filename.check_suffix name ".stdin"
      || Filename.check_suffix name ".stdout"
      || Filename.check_suffix name ".stderr")
  |> List.sort String.compare

let command = function Check -> "check" | Run -> "run" | Build -> "build" | Commands -> "sh"
let absolute path = if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

(* every build artifact, native object cache, and command working directory lives under one
   predictable, absolute scratch root: $TMPDIR/docs-doctest-scratch (under dune, TMPDIR is the
   build's own temporary directory, so nothing escapes the sandbox) *)
let scratch_root () =
  let temp_dir = match Sys.getenv_opt "TMPDIR" with Some path -> path | None -> "." in
  absolute (Filename.concat temp_dir "docs-doctest-scratch")

(* symbolic links are removed as links, never followed *)
let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let fresh_scratch_dir name =
  let root = scratch_root () in
  if not (Sys.file_exists root) then Unix.mkdir root 0o700;
  let dir = Filename.concat root name in
  remove_tree dir;
  Unix.mkdir dir 0o700;
  dir

let sanitize_environment bindings =
  bindings |> List.filter (fun binding -> not (String.starts_with ~prefix:"JACQUARD_" binding))

let hermetic_environment () =
  Unix.environment () |> Array.to_list |> sanitize_environment |> Array.of_list

let status_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal -> 128 + signal
  | Unix.WSTOPPED signal -> 128 + signal

(* [stdin_path] feeds the process a fixture instead of the harness's own standard input, which is
   what a documented interactive example needs; [environment] defaults to the hermetic one. *)
let capture_process ?stdin_path ?environment ~jacquard argv =
  (* absolute, so a process run from another working directory never sees the capture files *)
  let temp_dir = absolute (match Sys.getenv_opt "TMPDIR" with Some path -> path | None -> ".") in
  let stdout_path = Filename.temp_file ~temp_dir "docs-doctest-" ".stdout" in
  let stderr_path = Filename.temp_file ~temp_dir "docs-doctest-" ".stderr" in
  let environment =
    match environment with Some environment -> environment | None -> hermetic_environment ()
  in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists stdout_path then Sys.remove stdout_path;
      if Sys.file_exists stderr_path then Sys.remove stderr_path)
    (fun () ->
      let stdout_fd = Unix.openfile stdout_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let stderr_fd = Unix.openfile stderr_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let stdin_fd, close_stdin =
        match stdin_path with
        | Some path -> (Unix.openfile path [ Unix.O_RDONLY ] 0, true)
        | None -> (Unix.stdin, false)
      in
      let status =
        Fun.protect
          ~finally:(fun () ->
            Unix.close stdout_fd;
            Unix.close stderr_fd;
            if close_stdin then Unix.close stdin_fd)
          (fun () ->
            Unix.create_process_env jacquard argv environment stdin_fd stdout_fd stderr_fd
            |> Unix.waitpid [] |> snd)
      in
      (status_code status, read_file stdout_path, read_file stderr_path))

let assert_process_result label ~expected_exit ~expected_stdout ~expected_stderr
    (actual_exit, actual_stdout, actual_stderr) =
  if actual_exit <> expected_exit then
    failf "self-test %s: expected exit %d, actual %d" label expected_exit actual_exit;
  if actual_stdout <> expected_stdout then
    failf "self-test %s: expected stdout %S, actual %S" label expected_stdout actual_stdout;
  if actual_stderr <> expected_stderr then
    failf "self-test %s: expected stderr %S, actual %S" label expected_stderr actual_stderr

let expected_stream ~fixture_dir = function
  | None -> ""
  | Some artifact -> read_file (Filename.concat fixture_dir artifact)

let compare_stream ~example ~stream ~expected actual =
  if expected <> actual then
    failf "%s:%d: doctest %S %s mismatch\nexpected %S\nactual   %S" example.doc example.line
      example.name stream expected actual

(* a commands fixture sees `jacquard` first on its PATH (a wrapper in the scratch directory that
   runs the audited binary) and the audited prelude through JACQUARD_PRELUDE; everything else is
   the hermetic environment. It runs in a fresh scratch directory of its own. *)
let commands_environment ~prelude ~bin_dir =
  let path =
    match Sys.getenv_opt "PATH" with Some path -> bin_dir ^ ":" ^ path | None -> bin_dir
  in
  hermetic_environment () |> Array.to_list
  |> List.filter (fun binding -> not (String.starts_with ~prefix:"PATH=" binding))
  |> List.append [ "PATH=" ^ path; "JACQUARD_PRELUDE=" ^ absolute prelude ]
  |> Array.of_list

let run_fixture ~jacquard ~prelude ~fixture_dir example =
  let fixture = Filename.concat fixture_dir example.fixture in
  let stdin_path = Option.map (Filename.concat fixture_dir) example.stdin in
  let grants = List.concat_map (fun grant -> [ "--allow"; grant ]) example.grants in
  let actual_exit, actual_stdout, actual_stderr =
    match example.mode with
    | Check | Run ->
        let args =
          [ command example.mode; fixture; "--prelude"; prelude ]
          @ (match example.mode with Check -> [ "--print-sigs" ] | _ -> [])
          @ grants
        in
        capture_process ?stdin_path ~jacquard (Array.of_list (jacquard :: args))
    | Build ->
        let dir = fresh_scratch_dir example.name in
        let binary = Filename.concat dir "program" in
        let jacquard = absolute jacquard in
        let build_argv =
          Array.of_list
            [ jacquard; "build"; absolute fixture; "--prelude"; absolute prelude; "-o"; binary ]
        in
        (* the native object cache is written relative to the working directory, so build from
           the example's scratch directory and every artifact stays under it *)
        let stdin_path = Option.map absolute stdin_path in
        let cwd = Sys.getcwd () in
        Sys.chdir dir;
        Fun.protect
          ~finally:(fun () -> Sys.chdir cwd)
          (fun () ->
            let build_exit, build_stdout, build_stderr = capture_process ~jacquard build_argv in
            if build_exit <> 0 then
              failf "%s:%d: doctest %S native build failed (exit %d)\nstdout %S\nstderr %S"
                example.doc example.line example.name build_exit build_stdout build_stderr;
            (* the binary runs from the scratch directory as well, so a granted example's
               files land there and not in the build directory *)
            capture_process ?stdin_path ~jacquard:binary (Array.of_list (binary :: grants)))
    | Commands ->
        (* the script runs in an empty `work` directory of its own; the wrappers (`jacquard` and
           its documented alias `jac`) and the harness's capture files live beside it, never in
           it, so a listing example is pinnable and a fixture cannot corrupt the audit *)
        let dir = fresh_scratch_dir example.name in
        let bin_dir = Filename.concat dir "bin" in
        let work_dir = Filename.concat dir "work" in
        Unix.mkdir bin_dir 0o700;
        Unix.mkdir work_dir 0o700;
        let quoted =
          "'" ^ String.concat "'\\''" (String.split_on_char '\'' (absolute jacquard)) ^ "'"
        in
        List.iter
          (fun name ->
            let wrapper = Filename.concat bin_dir name in
            write_file wrapper (Printf.sprintf "#!/bin/sh\nexec %s \"$@\"\n" quoted);
            Unix.chmod wrapper 0o700)
          [ "jacquard"; "jac" ];
        let script = absolute fixture in
        let stdin_path = Option.map absolute stdin_path in
        let environment = commands_environment ~prelude ~bin_dir in
        let cwd = Sys.getcwd () in
        Sys.chdir work_dir;
        Fun.protect
          ~finally:(fun () -> Sys.chdir cwd)
          (fun () ->
            capture_process ?stdin_path ~environment ~jacquard:"/bin/sh"
              [| "/bin/sh"; "-e"; script |])
  in
  compare_stream ~example ~stream:"stdout"
    ~expected:(expected_stream ~fixture_dir example.stdout)
    actual_stdout;
  compare_stream ~example ~stream:"stderr"
    ~expected:(expected_stream ~fixture_dir example.stderr)
    actual_stderr;
  if actual_exit <> example.expected_exit then
    failf "%s:%d: doctest %S exit mismatch: expected %d, actual %d" example.doc example.line
      example.name example.expected_exit actual_exit

let audit ~execute ~jacquard ~prelude ~fixture_dir docs =
  List.iter
    (fun doc -> if Filename.basename doc = "tutorial.md" then audit_tutorial_commands doc)
    docs;
  let examples = List.concat_map extract docs in
  let seen_names = Hashtbl.create (List.length examples) in
  let seen_fixtures = Hashtbl.create (List.length examples) in
  let seen_artifacts = Hashtbl.create (List.length examples * 2) in
  List.iter
    (fun example ->
      (match Hashtbl.find_opt seen_names example.name with
      | Some first ->
          failf "%s:%d: duplicate doctest %S (first at %s:%d)" example.doc example.line example.name
            first.doc first.line
      | None -> Hashtbl.add seen_names example.name example);
      match Hashtbl.find_opt seen_fixtures example.fixture with
      | Some first ->
          failf "%s:%d: fixture %S is also used by doctest %S at %s:%d" example.doc example.line
            example.fixture first.name first.doc first.line
      | None ->
          Hashtbl.add seen_fixtures example.fixture example;
          Hashtbl.replace seen_artifacts example.fixture ())
    examples;
  List.iter
    (fun example ->
      let fixture = Filename.concat fixture_dir example.fixture in
      if not (Sys.file_exists fixture) then
        failf "%s:%d: doctest %S has no fixture %s" example.doc example.line example.name fixture;
      let fixture_source = read_file fixture in
      if fixture_source <> example.source then
        failf "%s:%d: doctest %S drifted from %s" example.doc example.line example.name fixture;
      List.iter
        (fun artifact ->
          if artifact <> "empty" && not (Sys.file_exists (Filename.concat fixture_dir artifact))
          then
            failf "%s:%d: doctest %S has no expectation %s" example.doc example.line example.name
              artifact;
          Hashtbl.replace seen_artifacts artifact ())
        (List.filter_map Fun.id [ example.stdin; example.stdout; example.stderr ]);
      if execute then run_fixture ~jacquard ~prelude ~fixture_dir example)
    examples;
  List.iter
    (fun artifact ->
      if not (Hashtbl.mem seen_artifacts artifact) then
        failf "%s/%s is not referenced by an audited doctest" fixture_dir artifact)
    (artifact_names fixture_dir);
  examples

let expect_failure label needle f =
  let rec contains_at message index =
    index + String.length needle <= String.length message
    && (String.sub message index (String.length needle) = needle || contains_at message (index + 1))
  in
  match f () with
  | () -> failf "self-test %s: expected failure containing %S" label needle
  | exception Failure message ->
      if needle = "" || not (contains_at message 0) then
        failf "self-test %s: expected %S in %S" label needle message
  | exception exn -> failf "self-test %s: unexpected exception %s" label (Printexc.to_string exn)

let with_test_dir label f =
  let root =
    let temp_dir = match Sys.getenv_opt "TMPDIR" with Some path -> path | None -> "." in
    Filename.concat temp_dir (Printf.sprintf "docs-doctest-self-%d-%s" (Unix.getpid ()) label)
  in
  let fixtures = Filename.concat root "fixtures" in
  let cleanup () =
    if Sys.file_exists fixtures then
      Sys.readdir fixtures |> Array.iter (fun name -> Sys.remove (Filename.concat fixtures name));
    if Sys.file_exists fixtures then Unix.rmdir fixtures;
    if Sys.file_exists root then (
      Sys.readdir root |> Array.iter (fun name -> Sys.remove (Filename.concat root name));
      Unix.rmdir root)
  in
  cleanup ();
  Unix.mkdir root 0o700;
  Unix.mkdir fixtures 0o700;
  Fun.protect ~finally:cleanup (fun () -> f root fixtures)

let marker ?(name = "case") ?(mode = "run") ?(fixture = "case.jac") ?(stdout = "case.stdout")
    ?(stderr = "empty") ?(exit = "0") source =
  Printf.sprintf "```jacquard doctest=%s mode=%s fixture=%s stdout=%s stderr=%s exit=%s\n%s```\n"
    name mode fixture stdout stderr exit source

let run_self_tests ~jacquard ~prelude =
  let inherited =
    [ "PATH=/bin"; "JACQUARD_PRELUDE=/host/prelude"; "HOME=/home/test"; "JACQUARD_TRACE=1" ]
  in
  let expected_environment = [ "PATH=/bin"; "HOME=/home/test" ] in
  let assert_environment_scrub sanitizer =
    if sanitizer inherited <> expected_environment then
      failf "self-test environment scrub: JACQUARD_* binding survived"
  in
  assert_environment_scrub sanitize_environment;
  expect_failure "environment scrub identity mutation" "JACQUARD_* binding survived" (fun () ->
      assert_environment_scrub Fun.id);
  expect_failure "missing field" "missing doctest field" (fun () ->
      ignore (parse_info ~doc:"self.md" ~line:1 "```jacquard doctest=x mode=run"));
  List.iter
    (fun (field, duplicate) ->
      expect_failure ("duplicate " ^ field) "duplicate doctest field" (fun () ->
          ignore
            (parse_info ~doc:"self.md" ~line:1
               ("```jacquard doctest=x mode=run fixture=x.jac stdout=empty stderr=empty exit=0 "
              ^ duplicate))))
    [
      ("doctest", "doctest=y");
      ("mode", "mode=check");
      ("fixture", "fixture=y.jac");
      ("stdout expectation", "stdout=y.stdout");
      ("stderr expectation", "stderr=y.stderr");
      ("exit", "exit=1");
      ("grants", "grants=fs grants=net");
    ];
  expect_failure "unknown field" "unknown doctest field" (fun () ->
      ignore
        (parse_info ~doc:"self.md" ~line:1
           "```jacquard doctest=x mode=run fixture=x.jac stdout=empty stderr=empty exit=0 \
            surprise=x"));
  with_test_dir "commands" (fun root _ ->
      let doc = Filename.concat root "tutorial.md" in
      write_file doc
        "Development-checkout commands assume the repo root and use\n`dune exec jacquard --`.\n";
      audit_tutorial_commands doc;
      write_file doc
        "Development-checkout commands assume the repo root and use\n\
         `dune exec jacquard --`.\n\
         Run `$ jac run example.jac`.\n";
      expect_failure "bare jac command" "bypasses" (fun () -> audit_tutorial_commands doc);
      write_file doc "Use `dune exec jacquard -- run example.jac`.\n";
      expect_failure "missing checkout setup" "command setup" (fun () ->
          audit_tutorial_commands doc));
  with_test_dir "audit" (fun root fixtures ->
      let doc = Filename.concat root "doc.md" in
      write_file (Filename.concat fixtures "case.jac") "1\n";
      write_file (Filename.concat fixtures "case.stdout") "1\n";
      let run () = ignore (audit ~execute:false ~jacquard ~prelude ~fixture_dir:fixtures [ doc ]) in
      write_file doc (marker "1\n");
      run ();
      write_file doc (marker ~fixture:"missing.jac" "1\n");
      expect_failure "missing fixture" "has no fixture" run;
      write_file doc (marker ~stdout:"missing.stdout" "1\n");
      expect_failure "missing expectation" "has no expectation" run;
      write_file doc (marker "2\n");
      expect_failure "divergent text" "drifted" run;
      write_file doc (marker "1\n" ^ marker ~name:"case" ~fixture:"other.jac" "1\n");
      expect_failure "duplicate name" "duplicate doctest" run;
      write_file doc "no examples\n";
      expect_failure "orphan fixture" "not referenced" run;
      Sys.remove (Filename.concat fixtures "case.jac");
      write_file doc (marker ~fixture:"other.jac" ~stdout:"empty" "1\n");
      write_file (Filename.concat fixtures "other.jac") "1\n";
      expect_failure "orphan expectation" "not referenced" run);
  with_test_dir "semantic" (fun root fixtures ->
      let doc = Filename.concat root "doc.md" in
      let fixture = Filename.concat fixtures "case.jac" in
      let stdout = Filename.concat fixtures "case.stdout" in
      let run source expected =
        write_file fixture source;
        write_file stdout expected;
        write_file doc (marker source);
        ignore (audit ~execute:true ~jacquard ~prelude ~fixture_dir:fixtures [ doc ])
      in
      run "add(1, 2)\n" "3\n";
      Unix.putenv "JACQUARD_PRELUDE" (Filename.concat root "bogus-prelude");
      run "add(1, 2)\n" "3\n";
      expect_failure "wrong output" "stdout mismatch" (fun () -> run "add(1, 3)\n" "3\n");
      let assert_rejected label source diagnostics =
        write_file fixture source;
        let argv = [| jacquard; "run"; fixture; "--prelude"; prelude |] in
        let expected_stderr =
          diagnostics
          |> List.map (fun diagnostic -> Printf.sprintf "%s:1:%s\n" fixture diagnostic)
          |> String.concat ""
        in
        let actual = capture_process ~jacquard argv in
        assert_process_result label ~expected_exit:1 ~expected_stdout:"" ~expected_stderr actual;
        expect_failure (label ^ " diagnostic mutation") "expected stderr" (fun () ->
            assert_process_result label ~expected_exit:1 ~expected_stdout:""
              ~expected_stderr:(expected_stderr ^ "unrelated diagnostic\n")
              actual);
        expect_failure (label ^ " status mutation") "expected exit" (fun () ->
            assert_process_result label ~expected_exit:0 ~expected_stdout:"" ~expected_stderr actual)
      in
      assert_rejected "raw fallback" "(app (var add) (lit 1) (lit 2))\n"
        [
          "11-14: error[E1220]: Surface syntax is invalid\n\
          \  Cause: expected `,` or `)`, found ident(add)\n\
          \  Next step: Correct the syntax at this location and parse the file again.";
          "21-22: error[E1220]: Surface syntax is invalid\n\
          \  Cause: expected `,` or `)`, found int(1)\n\
          \  Next step: Correct the syntax at this location and parse the file again.";
          "29-30: error[E1220]: Surface syntax is invalid\n\
          \  Cause: expected `,` or `)`, found int(2)\n\
          \  Next step: Correct the syntax at this location and parse the file again.";
        ];
      assert_rejected "recovery hole" "add(1,, 2)\n"
        [
          "7-8: error[E1220]: Surface syntax is invalid\n\
          \  Cause: expected an expression, found ,\n\
          \  Next step: Correct the syntax at this location and parse the file again.";
          "9-10: error[E1220]: Surface syntax is invalid\n\
          \  Cause: expected `,` or `)`, found int(2)\n\
          \  Next step: Correct the syntax at this location and parse the file again.";
        ]);
  with_test_dir "signature" (fun root fixtures ->
      let doc = Filename.concat root "doc.md" in
      let fixture = Filename.concat fixtures "case.jac" in
      let stdout = Filename.concat fixtures "case.stdout" in
      write_file fixture "fn (x) -> x\n";
      write_file stdout "_ : forall a. (a) ->{} a\n";
      write_file doc (marker ~mode:"check" "fn (x) -> x\n");
      ignore (audit ~execute:true ~jacquard ~prelude ~fixture_dir:fixtures [ doc ]);
      write_file fixture "fn (x) -> 1\n";
      write_file doc (marker ~mode:"check" "fn (x) -> 1\n");
      expect_failure "wrong signature" "stdout mismatch" (fun () ->
          ignore (audit ~execute:true ~jacquard ~prelude ~fixture_dir:fixtures [ doc ]));
      write_file fixture "read-note() = fs.read-only(fn () -> read(\"note.txt\"))\n";
      write_file stdout "read-note : () ->{Fs, Throw} Text\n";
      write_file doc
        (marker ~mode:"check" "read-note() = fs.read-only(fn () -> read(\"note.txt\"))\n");
      ignore (audit ~execute:true ~jacquard ~prelude ~fixture_dir:fixtures [ doc ]);
      write_file fixture "read-note() = \"note\"\n";
      write_file doc (marker ~mode:"check" "read-note() = \"note\"\n");
      expect_failure "residual Fs row mutation" "stdout mismatch" (fun () ->
          ignore (audit ~execute:true ~jacquard ~prelude ~fixture_dir:fixtures [ doc ])));
  (* APP.10: interactive input, native builds, and command snippets are audited the same way *)
  with_test_dir "stdin-build" (fun root fixtures ->
      let doc = Filename.concat root "doc.md" in
      let fixture = Filename.concat fixtures "case.jac" in
      write_file fixture "(read-line(), next-line(), next-line())\n";
      write_file (Filename.concat fixtures "case.stdin") "hi\nthere\n";
      write_file (Filename.concat fixtures "case.stdout") "(\"hi\", some(\"there\"), none)\n";
      let fence mode =
        Printf.sprintf
          "```jacquard doctest=case mode=%s fixture=case.jac stdin=case.stdin stdout=case.stdout \
           stderr=empty exit=0 grants=console\n\
           (read-line(), next-line(), next-line())\n\
           ```\n"
          mode
      in
      write_file doc (fence "run");
      ignore (audit ~execute:true ~jacquard ~prelude ~fixture_dir:fixtures [ doc ]);
      write_file doc (fence "build");
      ignore (audit ~execute:true ~jacquard ~prelude ~fixture_dir:fixtures [ doc ]);
      write_file (Filename.concat fixtures "case.stdin") "hi\n";
      expect_failure "stdin mutation" "stdout mismatch" (fun () ->
          ignore (audit ~execute:true ~jacquard ~prelude ~fixture_dir:fixtures [ doc ]));
      write_file doc (fence "check");
      expect_failure "check takes no stdin" "takes no stdin" (fun () ->
          ignore (audit ~execute:false ~jacquard ~prelude ~fixture_dir:fixtures [ doc ])));
  with_test_dir "commands" (fun root fixtures ->
      let doc = Filename.concat root "doc.md" in
      let script = Filename.concat fixtures "case.sh" in
      let fence source =
        Printf.sprintf
          "```sh doctest=case mode=commands fixture=case.sh stdout=case.stdout stderr=empty exit=0\n\
           %s```\n"
          source
      in
      (* the work directory starts empty and stays free of harness files; `jac` is wrapped too *)
      let source = "ls -A\nprintf 'add(1, 2)\\n' > program.jac\njac run program.jac\nls -A\n" in
      write_file script source;
      write_file (Filename.concat fixtures "case.stdout") "3\nprogram.jac\n";
      write_file doc (fence source);
      ignore (audit ~execute:true ~jacquard ~prelude ~fixture_dir:fixtures [ doc ]);
      let stale = source ^ "jacquard no-such-command\n" in
      write_file script stale;
      write_file doc (fence stale);
      expect_failure "stale command" "mismatch" (fun () ->
          ignore (audit ~execute:true ~jacquard ~prelude ~fixture_dir:fixtures [ doc ]));
      write_file doc
        ("```jacquard doctest=case mode=commands fixture=case.sh stdout=case.stdout stderr=empty \
          exit=0\n" ^ stale ^ "```\n");
      expect_failure "commands need a sh fence" "needs mode=commands" (fun () ->
          ignore (audit ~execute:false ~jacquard ~prelude ~fixture_dir:fixtures [ doc ])));
  Printf.printf "docs-doctest self-test: ok\n"

let () =
  (* TMPDIR is resolved once, before any example changes the working directory: a relative value
     (the dune rule's `.`) must keep pointing at the harness's own directory, never at a scratch
     directory a snippet is running in *)
  Unix.putenv "TMPDIR"
    (absolute (match Sys.getenv_opt "TMPDIR" with Some path -> path | None -> "."));
  try
    if Array.length Sys.argv >= 2 && Sys.argv.(1) = "--self-test" then (
      if Array.length Sys.argv <> 4 then failf "usage: docs_doctest --self-test JACQUARD PRELUDE";
      run_self_tests ~jacquard:Sys.argv.(2) ~prelude:Sys.argv.(3))
    else (
      if Array.length Sys.argv < 5 then failf "usage: docs_doctest JACQUARD PRELUDE FIXTURES DOC...";
      let jacquard = Sys.argv.(1) in
      let prelude = Sys.argv.(2) in
      let fixture_dir = Sys.argv.(3) in
      let docs = Array.to_list (Array.sub Sys.argv 4 (Array.length Sys.argv - 4)) in
      let examples = audit ~execute:true ~jacquard ~prelude ~fixture_dir docs in
      (* the runtime/prelude pair the examples were executed against *)
      let version =
        match capture_process ~jacquard [| jacquard; "--version" |] with
        | 0, stdout, _ -> String.trim stdout
        | code, _, _ -> failf "`jacquard --version` failed with exit %d" code
      in
      let by_mode mode = List.length (List.filter (fun example -> example.mode = mode) examples) in
      Printf.printf
        "docs-doctest: %d examples from %d documents (%d check, %d run, %d build, %d commands) \
         against jacquard %s with prelude %s\n"
        (List.length examples) (List.length docs) (by_mode Check) (by_mode Run) (by_mode Build)
        (by_mode Commands) version prelude)
  with Failure message ->
    prerr_endline ("docs-doctest: " ^ message);
    exit 1
