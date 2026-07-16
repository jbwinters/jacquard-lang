open Jacquard

(* W6.6 codecs/record/replay/scripted worlds, W6.7 fault injection. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_ok src =
  match Eval_support.eval_with ctx store src with
  | Ok v -> v
  | Error e -> Alcotest.failf "eval failed on %s: %s" src (Runtime_err.to_string e)

let show src = Value.show (eval_ok src)
let quote s = "\"" ^ Printer.escape_text s ^ "\""

(* --- codec round-trips (decode after encode = some, qcheck) --- *)

let prop_codec_text =
  QCheck.Test.make ~count:120 ~name:"codec.text round-trips"
    (QCheck.make
       QCheck.Gen.(string_size ~gen:(oneof_list [ 'a'; 'z'; ' '; '"'; '\\'; '\n' ]) (int_bound 12)))
    (fun s ->
      show
        (Printf.sprintf
           "(app (app (var codec.decode) (var codec.text)) (app (app (var codec.encode) (var \
            codec.text)) (lit %s)))"
           (quote s))
      = Printf.sprintf "some(%s)" (Value.show (Value.VText s)))

let prop_codec_int =
  QCheck.Test.make ~count:120 ~name:"codec.int round-trips" QCheck.int (fun n ->
      show
        (Printf.sprintf
           "(app (app (var codec.decode) (var codec.int)) (app (app (var codec.encode) (var \
            codec.int)) (lit %d)))"
           n)
      = Printf.sprintf "some(%d)" n)

let test_codec_records_roundtrip () =
  Alcotest.(check string)
    "request" "some(mk-request(\"http://x\", \"payload\"))"
    (show
       "(app (app (var codec.decode) (var codec.request)) (app (app (var codec.encode) (var \
        codec.request)) (app (var mk-request) (lit \"http://x\") (lit \"payload\"))))");
  Alcotest.(check string)
    "response" "some(mk-response(503, \"nope\"))"
    (show
       "(app (app (var codec.decode) (var codec.response)) (app (app (var codec.encode) (var \
        codec.response)) (app (var mk-response) (lit 503) (lit \"nope\"))))");
  Alcotest.(check string)
    "list of text" "some(cons(\"a\", cons(\"b\", nil)))"
    (show
       "(app (app (var codec.decode) (app (var codec.list) (var codec.text))) (app (app (var \
        codec.encode) (app (var codec.list) (var codec.text))) (app (var cons) (lit \"a\") (app \
        (var cons) (lit \"b\") (var nil)))))");
  (* decode rejects a wrong head *)
  Alcotest.(check string)
    "wrong head decodes to none" "none"
    (show
       "(app (app (var codec.decode) (var codec.request)) (app (var code.form) (lit \"banana\") \
        (var nil)))")

(* --- record / replay --- *)

let agent =
  "(lam () (match (app (var fetch) (app (var mk-request) (lit \"http://a\") (lit \"\"))) (clause \
   (pcon mk-response (pwild) (pvar b1)) (match (app (var fetch) (app (var mk-request) (lit \
   \"http://b\") (lit \"\"))) (clause (pcon mk-response (pwild) (pvar b2)) (app (var text.concat) \
   (var b1) (var b2)))))))"

let canned =
  "(app (var cons) (app (var mk-response) (lit 200) (lit \"first.\")) (app (var cons) (app (var \
   mk-response) (lit 200) (lit \"second.\")) (var nil)))"

let record_expr =
  Printf.sprintf "(app (var net.scripted) (lam () (app (var net.record) %s)) %s)" agent canned

let test_record_then_strict_replay () =
  Alcotest.(check string)
    "recorded result and replayed result agree" "(\"first.second.\", \"first.second.\")"
    (show
       (Printf.sprintf
          "(match %s (clause (ptuple (pvar result) (pvar log)) (tuple (var result) (app (var \
           test.replay) (var log) %s))))"
          record_expr agent))

(* the drift contract: a DIFFERENT agent (changed request) diverges with the differ's
   smallest disagreeing subtree naming the changed leaf *)
let test_strict_replay_drift_diff () =
  let drifted =
    "(lam () (match (app (var fetch) (app (var mk-request) (lit \"http://CHANGED\") (lit \"\"))) \
     (clause (pcon mk-response (pwild) (pvar b)) (var b))))"
  in
  Alcotest.(check string)
    "golden divergence diff"
    "\"test.replay diverged: at log/request[0]/lit[0]: - \\\"http://a\\\" + \
     \\\"http://CHANGED\\\"\""
    (show
       (Printf.sprintf
          "(match %s (clause (ptuple (pwild) (pvar log)) (app (var throw.catch) (lam () (app (var \
           test.replay) (var log) %s)) (lam ((pvar e)) (var e)))))"
          record_expr drifted))

(* loose mode tolerates reordering and warns on leftovers *)
let test_loose_replay_reorders_and_warns () =
  let reordered =
    "(lam () (match (app (var fetch) (app (var mk-request) (lit \"http://b\") (lit \"\"))) (clause \
     (pcon mk-response (pwild) (pvar b)) (var b))))"
  in
  (* fetch b FIRST: strict would diverge; loose matches anywhere, then warns about the
     unconsumed http://a entry through a passing check *)
  Alcotest.(check string)
    "reordered fetch served; leftover warned"
    "mk-report(cons((\"test.replay-loose: leftover log entries (warning)\", true), nil), none)"
    (show
       (Printf.sprintf
          "(match %s (clause (ptuple (pwild) (pvar log)) (app (var test.run) (lam () (let nonrec \
           (pvar r) (app (var test.replay-loose) (var log) %s) (tuple))))))"
          record_expr reordered))

(* --- scripted worlds --- *)

let test_fs_in_memory () =
  Alcotest.(check string)
    "write/read/list through the map-backed world"
    "(\"hello\", cons(\"a.txt\", cons(\"b.txt\", nil)))"
    (show
       "(match (app (var fs.in-memory) (lam () (let nonrec (pwild) (app (var write) (lit \
        \"b.txt\") (lit \"hello\")) (tuple (app (var read) (lit \"b.txt\")) (app (var list-dir) \
        (lit \".\"))))) (app (var map.set) (app (var map.empty) (var text.ord)) (lit \"a.txt\") \
        (lit \"seed\"))) (clause (ptuple (pvar out) (pwild)) (var out)))");
  Alcotest.(check string)
    "missing file throws through ring 1" "\"fs.in-memory: no such file: ghost\""
    (show
       "(app (var throw.catch) (lam () (match (app (var fs.in-memory) (lam () (app (var read) (lit \
        \"ghost\"))) (app (var map.empty) (var text.ord))) (clause (ptuple (pvar x) (pwild)) (var \
        x)))) (lam ((pvar e)) (var e)))")

let test_clock_fixed_and_console_scripted () =
  Alcotest.(check string)
    "fixed clock, scripted console" "(1234, \"hi\")"
    (show
       "(app (var clock.fixed) (lam () (app (var console.scripted) (lam () (tuple (app (var now)) \
        (app (var read-line)))) (app (var cons) (lit \"hi\") (var nil)))) (lit 1234))");
  Alcotest.(check string)
    "scripted Net leaves caller State outward" "(9, 9)"
    (show
       "(app (var state.run) (lam () (app (var net.scripted) (lam () (let nonrec (pwild) (app (var \
        put) (lit 9)) (let nonrec (pwild) (app (var fetch) (app (var mk-request) (lit \
        \"http://state\") (lit \"\"))) (app (var get))))) (app (var cons) (app (var mk-response) \
        (lit 200) (lit \"ok\")) (var nil)))) (lit 0))")

(* --- W6.7 fault --- *)

let test_fault_all_explores_all_paths () =
  (* 3 sites -> exactly 8 executions, each check labeled with its fault path *)
  let r =
    show
      "(app (var test.run) (lam () (let nonrec (pvar results) (app (var throw.catch) (lam () (app \
       (var fault.all) (lam () (let nonrec (pvar a) (app (var flaky) (lit \"s1\")) (let nonrec \
       (pvar b) (app (var flaky) (lit \"s2\")) (let nonrec (pvar c) (app (var flaky) (lit \"s3\")) \
       (app (var check.true) (var true) (lit \"done\")))))) (lit 10000))) (lam ((pwild)) (var \
       nil))) (app (var check.eq) (app (var list.length) (var results)) (lit 8) (var int.eq) (var \
       int.show) (lit \"8 executions\")))))"
  in
  (* count entries: 8 path checks + the final count check, all passing, no hard *)
  let rec count_entries s i acc =
    if i + 5 > String.length s then acc
    else if String.sub s i 5 = "cons(" then count_entries s (i + 5) (acc + 1)
    else count_entries s (i + 1) acc
  in
  Alcotest.(check int) "nine report entries (8 paths + count)" 9 (count_entries r 0 0);
  Alcotest.(check bool)
    "no failures" true
    (not
       (let re = "false" in
        let rec has i =
          i + String.length re <= String.length r
          && (String.sub r i (String.length re) = re || has (i + 1))
        in
        has 0))

(* retry-up-to-3 survives every single- and double-fault path; the triple-fault path
   fails — one report carries all four paths *)
let test_retry_under_fault_all () =
  let r =
    show
      "(app (var test.run) (lam () (let nonrec (pwild) (app (var throw.catch) (lam () (app (var \
       fault.all) (lam () (app (var net.scripted) (lam () (let nonrec (pvar outcome) (app (var \
       throw.catch) (lam () (match (app (var net.with-retries) (app (var mk-request) (lit \"u\") \
       (lit \"\")) (lit 3)) (clause (pcon mk-response (pwild) (pwild)) (lit \"ok\")))) (lam ((pvar \
       e)) (var e))) (app (var check.eq) (var outcome) (lit \"ok\") (var text.eq) (var text.show) \
       (lit \"retry survived\")))) (app (var cons) (app (var mk-response) (lit 200) (lit \"r1\")) \
       (app (var cons) (app (var mk-response) (lit 200) (lit \"r2\")) (app (var cons) (app (var \
       mk-response) (lit 200) (lit \"r3\")) (var nil)))))) (lit 10000))) (lam ((pwild)) (var \
       nil))) (tuple))))"
  in
  (* paths: ok / F,ok / F,F,ok / F,F,F(fail) — three passes, one failure *)
  let count needle s =
    let nl = String.length needle in
    let rec go i acc =
      if i + nl > String.length s then acc
      else go (i + 1) (if String.sub s i nl = needle then acc + 1 else acc)
    in
    go 0 0
  in
  Alcotest.(check int) "four explored paths" 4 (count "retry survived" r);
  Alcotest.(check int) "exactly one failing path (the triple fault)" 1 (count ", false)" r);
  Alcotest.(check int)
    "the failing path is the triple fault" 1
    (count "net.fetch=FAULT net.fetch=FAULT net.fetch=FAULT" r)

let test_fault_random_deterministic () =
  let run seed =
    show
      (Printf.sprintf
         "(app (var test.run) (lam () (app (var fault.random) (lam () (let nonrec (pvar a) (app \
          (var flaky) (lit \"x\")) (let nonrec (pvar b) (app (var flaky) (lit \"y\")) (app (var \
          check.true) (var true) (app (var text.concat) (lit \"path \") (match (tuple (var a) (var \
          b)) (clause (ptuple (pcon true) (pcon true)) (lit \"tt\")) (clause (ptuple (pcon true) \
          (pcon false)) (lit \"tf\")) (clause (ptuple (pcon false) (pcon true)) (lit \"ft\")) \
          (clause (ptuple (pcon false) (pcon false)) (lit \"ff\")))))))) (lit 50) (lit %d))))"
         seed)
  in
  Alcotest.(check string) "same seed, same chaos" (run 42) (run 42);
  Alcotest.(check bool)
    "different seeds may differ (do, for 42 vs 43)" true
    (run 42 <> run 43 || run 42 <> run 7)

let test_fault_all_budget_refusal () =
  (* a 20-site body under fuel 10000 < 2^20 throws the refusal naming a site *)
  let sites =
    String.concat " "
      (List.init 20 (fun i ->
           Printf.sprintf "(let nonrec (pwild) (app (var flaky) (lit \"s%d\"))" i))
  in
  let closers = String.concat "" (List.init 20 (fun _ -> ")")) in
  let r =
    show
      (Printf.sprintf
         "(app (var throw.catch) (lam () (match (app (var fault.all) (lam () %s (tuple) %s) (lit \
          10000)) (clause (pwild) (lit \"completed\")))) (lam ((pvar e)) (var e)))"
         sites closers)
  in
  Alcotest.(check bool)
    ("refusal names the budget story: " ^ r)
    true
    (let re = "exploration budget exceeded" in
     let rec has i =
       i + String.length re <= String.length r
       && (String.sub r i (String.length re) = re || has (i + 1))
     in
     has 0)

(* FoundationDB-style DST from library parts: clock.fixed + scripted world + fault.all
   is bit-deterministic — run twice, byte-identical *)
let test_dst_byte_identical () =
  let run () =
    show
      "(app (var test.run) (lam () (app (var clock.fixed) (lam () (let nonrec (pwild) (app (var \
       throw.catch) (lam () (app (var fault.all) (lam () (app (var net.scripted) (lam () (let \
       nonrec (pvar t) (app (var now)) (match (app (var net.try-fetch) (app (var mk-request) (lit \
       \"u\") (lit \"\"))) (clause (pcon ok (pcon mk-response (pwild) (pvar b))) (app (var \
       check.true) (var true) (app (var text.concat) (var b) (app (var text.from-int) (var t))))) \
       (clause (pcon err (pvar e)) (app (var check.true) (var true) (var e)))))) (app (var cons) \
       (app (var mk-response) (lit 200) (lit \"body\")) (var nil)))) (lit 1000))) (lam ((pwild)) \
       (var nil))) (tuple))) (lit 99))))"
  in
  Alcotest.(check string) "run twice, byte-identical" (run ()) (run ())

(* the seed is visible in every chaos report entry, so failures reproduce *)
let test_fault_random_seed_in_report () =
  let r =
    show
      "(app (var test.run) (lam () (app (var fault.random) (lam () (let nonrec (pwild) (app (var \
       flaky) (lit \"x\")) (app (var check.true) (var false) (lit \"chaos failure\")))) (lit 50) \
       (lit 987654))))"
  in
  let has needle s =
    let nl = String.length needle and hl = String.length s in
    let rec go i = i + nl <= hl && (String.sub s i nl = needle || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool) ("report names the seed: " ^ r) true (has "seed=987654 chaos failure" r)

let suite =
  [
    QCheck_alcotest.to_alcotest prop_codec_text;
    QCheck_alcotest.to_alcotest prop_codec_int;
    Alcotest.test_case "record codecs round-trip" `Quick test_codec_records_roundtrip;
    Alcotest.test_case "record then strict replay" `Quick test_record_then_strict_replay;
    Alcotest.test_case "strict replay drift renders the diff" `Quick test_strict_replay_drift_diff;
    Alcotest.test_case "loose replay reorders, warns leftovers" `Quick
      test_loose_replay_reorders_and_warns;
    Alcotest.test_case "fs.in-memory over state and map" `Quick test_fs_in_memory;
    Alcotest.test_case "clock.fixed and console.scripted" `Quick
      test_clock_fixed_and_console_scripted;
    Alcotest.test_case "fault.all explores all 2^n paths" `Quick test_fault_all_explores_all_paths;
    Alcotest.test_case "retry survives up to two faults, fails on three" `Quick
      test_retry_under_fault_all;
    Alcotest.test_case "fault.random is seed-deterministic" `Quick test_fault_random_deterministic;
    Alcotest.test_case "fault.all budget refusal" `Quick test_fault_all_budget_refusal;
    Alcotest.test_case "DST: run twice, byte-identical" `Quick test_dst_byte_identical;
    Alcotest.test_case "fault.random names its seed in the report" `Quick
      test_fault_random_seed_in_report;
  ]
