open Weft

(* SL.8/SL.10: world-effect root handlers with injected primitives, the read-only
   interposition handler, debug.inspect, and the infer fixtures. *)

let fresh_ctx () = Eval_support.make_prelude_ctx ()

let eval_in (store, ctx) src =
  match Eval_support.eval_with ctx store src with
  | Ok v -> v
  | Error e -> Alcotest.failf "eval failed on %s: %s" src (Runtime_err.to_string e)

let show h src = Value.show (eval_in h src)

let test_clock_injected () =
  let ((_, ctx) as h) = fresh_ctx () in
  let slept = ref [] in
  (match
     Prelude.install_clock ~now:(fun () -> 1234) ~sleep:(fun ms -> slept := ms :: !slept) ctx
   with
  | Ok () -> ()
  | Error ds -> Eval_support.fail_diags "install_clock" ds);
  Alcotest.(check string) "now" "1234" (show h "(app (var now))");
  ignore (eval_in h "(app (var sleep) (lit 250))");
  Alcotest.(check (list int)) "sleep called with ms" [ 250 ] !slept

let test_console_read_line_injected () =
  let ((_, ctx) as h) = fresh_ctx () in
  let script = ref [ "first"; "second" ] in
  let read_line () =
    match !script with
    | x :: rest ->
        script := rest;
        x
    | [] -> ""
  in
  (match Prelude.install_console ~read_line ctx ~out:ignore with
  | Ok () -> ()
  | Error ds -> Eval_support.fail_diags "install_console" ds);
  Alcotest.(check string)
    "two reads in order" "(\"first\", \"second\")"
    (show h "(tuple (app (var read-line)) (app (var read-line)))")

let with_tmpdir f =
  let dir = Filename.temp_file "weft-fs" "" in
  Sys.remove dir;
  Sys.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun e -> Sys.remove (Filename.concat dir e)) (Sys.readdir dir);
      Sys.rmdir dir)
    (fun () -> f dir)

let test_fs_roundtrip_and_readonly () =
  with_tmpdir (fun dir ->
      let ((_, ctx) as h) = fresh_ctx () in
      (match Prelude.install_fs ctx with
      | Ok () -> ()
      | Error ds -> Eval_support.fail_diags "install_fs" ds);
      let path = Filename.concat dir "f.txt" in
      Alcotest.(check string)
        "write-read roundtrip" "\"payload\""
        (show h
           (Printf.sprintf
              "(let nonrec (pwild) (app (var write) (lit \"%s\") (lit \"payload\")) (app (var \
               read) (lit \"%s\")))"
              path path));
      Alcotest.(check string)
        "list-dir" "cons(\"f.txt\", nil)"
        (show h (Printf.sprintf "(app (var list-dir) (lit \"%s\"))" dir));
      (* the interposition tutorial: reads forward, writes throw, the file survives *)
      Alcotest.(check string)
        "read-only refuses write" "\"fs.read-only refused write: forbidden.txt\""
        (show h
           (Printf.sprintf
              "(app (var throw.catch) (lam () (app (var fs.read-only) (lam () (let nonrec (pvar c) \
               (app (var read) (lit \"%s\")) (let nonrec (pwild) (app (var write) (lit \
               \"forbidden.txt\") (lit \"x\")) (var c)))))) (lam ((pvar e)) (var e)))"
              path));
      Alcotest.(check string)
        "reads pass through read-only" "\"payload\""
        (show h
           (Printf.sprintf "(app (var fs.read-only) (lam () (app (var read) (lit \"%s\"))))" path));
      (* IO failure is a clean runtime error, not a crash *)
      match Eval_support.eval_with ctx (fst h) "(app (var read) (lit \"/nonexistent-weft\"))" with
      | Error (Runtime_err.Io _) -> ()
      | r ->
          Alcotest.failf "missing file must be Io, got %s"
            (match r with Ok v -> Value.show v | Error e -> Runtime_err.to_string e))

let test_fs_readonly_missing_grant_still_refused () =
  (* fs.read-only FORWARDS to the real world, so the row keeps fs: without the grant
     the manifest (or here, the bare evaluator) still refuses *)
  let ((_, _) as h) = fresh_ctx () in
  match
    Eval_support.eval_with (snd h) (fst h)
      "(app (var fs.read-only) (lam () (app (var read) (lit \"x\"))))"
  with
  | Error (Runtime_err.Unhandled { effect_ = "fs"; _ }) -> ()
  | r ->
      Alcotest.failf "expected unhandled fs, got %s"
        (match r with Ok v -> Value.show v | Error e -> Runtime_err.to_string e)

let test_debug_inspect_matches_value_show () =
  let h = fresh_ctx () in
  List.iter
    (fun (src, v) ->
      Alcotest.(check string)
        src
        (Value.show (Value.VText (Value.show v)))
        (show h (Printf.sprintf "(app (var debug.inspect) %s)" src)))
    [
      ("(lit 42)", Value.VInt 42);
      ("(lit \"hi\")", Value.VText "hi");
      ( "(tuple (lit 1) (var true))",
        Value.VTuple
          [ Value.VInt 1; Value.VCon { con = Hash.of_string "x"; name = "true"; args = [] } ] );
    ];
  (* a composite: the rendering goes through Value.show verbatim *)
  Alcotest.(check string)
    "list rendering" "\"cons(1, nil)\""
    (show h "(app (var debug.inspect) (app (var cons) (lit 1) (var nil)))")

let test_infer_stub_and_cache () =
  with_tmpdir (fun dir ->
      let run_once () =
        let ((_, ctx) as h) = fresh_ctx () in
        (match Prelude.install_infer ~cache_dir:dir ctx with
        | Ok () -> ()
        | Error ds -> Eval_support.fail_diags "install_infer" ds);
        show h "(app (var complete) (app (var mk-prompt) (lit \"plan the day\") (var none)))"
      in
      let first = run_once () in
      Alcotest.(check string) "stub completion" "\"<stub completion for: plan the day>\"" first;
      Alcotest.(check int) "one cache entry" 1 (Array.length (Sys.readdir dir));
      (* second run in a FRESH context: full hit, same completion *)
      Alcotest.(check string) "cache hit reproduces" first (run_once ());
      Alcotest.(check int) "still one entry" 1 (Array.length (Sys.readdir dir));
      (* the entry is a printed form the reader accepts *)
      let entry = Filename.concat dir (Sys.readdir dir).(0) in
      let ic = open_in_bin entry in
      let src = really_input_string ic (in_channel_length ic) in
      close_in ic;
      match Reader.parse_one ~file:entry src with
      | Ok { Form.head = "infer-cache-entry"; _ } -> ()
      | Ok f -> Alcotest.failf "unexpected cache form %s" f.Form.head
      | Error ds -> Eval_support.fail_diags "cache entry parse" ds)

let test_infer_scripted_model_swap () =
  let h = fresh_ctx () in
  let agent = "(lam () (app (var complete) (app (var mk-prompt) (lit \"q\") (var none))))" in
  let under script =
    show h
      (Printf.sprintf
         "(app (var throw.catch) (lam () (app (var infer.scripted) %s %s)) (lam ((pvar e)) (var \
          e)))"
         agent script)
  in
  Alcotest.(check string)
    "model a" "\"a says\""
    (under "(app (var cons) (lit \"a says\") (var nil))");
  Alcotest.(check string)
    "model b" "\"b says\""
    (under "(app (var cons) (lit \"b says\") (var nil))");
  Alcotest.(check string)
    "exhaustion throws" "\"infer.scripted: out of canned completions\"" (under "(var nil)")

let suite =
  [
    Alcotest.test_case "clock with injected primitives" `Quick test_clock_injected;
    Alcotest.test_case "console read-line injected" `Quick test_console_read_line_injected;
    Alcotest.test_case "fs roundtrip and read-only interposition" `Quick
      test_fs_roundtrip_and_readonly;
    Alcotest.test_case "read-only without grant still refuses" `Quick
      test_fs_readonly_missing_grant_still_refused;
    Alcotest.test_case "debug.inspect matches Value.show" `Quick
      test_debug_inspect_matches_value_show;
    Alcotest.test_case "infer stub and content-addressed cache" `Quick test_infer_stub_and_cache;
    Alcotest.test_case "infer.scripted model swap" `Quick test_infer_scripted_model_swap;
  ]
