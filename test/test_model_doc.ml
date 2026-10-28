open Jacquard
module M = Model_doc

let prelude_dir = "../prelude"

let fresh_dir =
  let serial = ref 0 in
  fun label ->
    incr serial;
    let dir =
      Filename.concat (Filename.get_temp_dir_name ())
        (Printf.sprintf "jacquard-model-%s-%d-%d" label (Unix.getpid ()) !serial)
    in
    Unix.mkdir dir 0o700;
    dir

let write dir name contents =
  Out_channel.with_open_bin (Filename.concat dir name) (fun oc -> output_string oc contents)

let codes ds = List.filter_map Diag.code ds

let source =
  String.concat "\n"
    [
      "helper(x) = add(x, 2)";
      "other(x) = add(x, 1)";
      "scale(n, k) = helper(add(n, k))";
      "shift(n) = other(n)";
      "apply(f, n) = f(n)";
      "echo(t) = t";
      "greet(t) = print(t)";
      "coin(p) = sample(Bernoulli(p))";
      "";
    ]

let document =
  String.concat "\n"
    [
      "jacquard-model format=1";
      "# a comment";
      "source m.jac";
      "assumption base = 3";
      "assumption step = 4";
      "assumption chance = 0.3";
      "input note text note.txt";
      "";
      "result scaled entry scale args base,step driver run fuel=1000";
      "result shifted entry shift args base driver run fuel=1000";
      "result applied entry apply args helper,5 driver run fuel=1000";
      "result echoed entry echo args note driver run fuel=1000";
      "result greeted entry greet args note driver run fuel=1000";
      "result flip entry coin args chance driver lw seed=7 samples=100 fuel=100000";
      "result flip-exact entry coin args chance driver enumerate max-branches=10 fuel=100000";
      "";
    ]

let parse_ok text =
  match M.parse ~file:"doc.model" text with
  | Ok doc -> doc
  | Error ds -> Alcotest.failf "parse failed: %s" (String.concat "; " (List.map Diag.to_string ds))

(* prepare a document over files in a fresh directory, returning result name -> resolved *)
let prepare ?(files = []) ?(src = source) ?(doc = document) label =
  let dir = fresh_dir label in
  write dir "m.jac" src;
  write dir "note.txt" "hello";
  List.iter (fun (n, c) -> write dir n c) files;
  let file = Filename.concat dir "doc.model" in
  write dir "doc.model" doc;
  let root = Filename.concat (fresh_dir (label ^ "-store")) "store" in
  match M.parse ~file doc with
  | Error ds -> Error ds
  | Ok parsed -> M.prepare ~prelude_dir ~root ~file parsed

let prepared ?files ?src ?doc label =
  match prepare ?files ?src ?doc label with
  | Ok p -> List.map (fun (r : M.resolved) -> (r.M.decl.M.r_name, r)) p.M.resolved
  | Error ds ->
      Alcotest.failf "prepare failed: %s" (String.concat "; " (List.map Diag.to_string ds))

let keys rs = List.map (fun (n, (r : M.resolved)) -> (n, Hash.to_hex (M.key r.M.dependency))) rs

let contains text part =
  let n = String.length part in
  let rec at i = i + n <= String.length text && (String.sub text i n = part || at (i + 1)) in
  at 0

let refused label code ?(cause = "") ?files ?src ?doc () =
  match prepare ?files ?src ?doc label with
  | Ok _ -> Alcotest.failf "%s: expected %s" label code
  | Error ds ->
      Alcotest.(check (option string)) label (Some code) (List.nth_opt (codes ds) 0);
      let first = Diag.cause (List.hd ds) in
      if not (contains first cause) then Alcotest.failf "%s: cause %S lacks %S" label first cause

let test_parse () =
  let doc = parse_ok document in
  Alcotest.(check string) "source" "m.jac" doc.M.source;
  Alcotest.(check int) "assumptions" 3 (List.length doc.M.assumptions);
  Alcotest.(check int) "results" 7 (List.length doc.M.results);
  let flip = List.find (fun (r : M.result_decl) -> r.M.r_name = "flip") doc.M.results in
  Alcotest.(check bool) "lw driver" true (flip.M.r_driver = M.Lw { seed = 7; samples = 100 });
  let applied = List.find (fun (r : M.result_decl) -> r.M.r_name = "applied") doc.M.results in
  Alcotest.(check bool)
    "inline literal" true
    (applied.M.r_arguments = [ M.Named "helper"; M.Inline "5" ])

let test_parse_refusals () =
  let refused label code text =
    match M.parse ~file:"doc.model" text with
    | Ok _ -> Alcotest.failf "%s: accepted" label
    | Error ds -> Alcotest.(check (list string)) label [ code ] (codes ds)
  in
  let replace a b = Str.global_replace (Str.regexp_string a) b document in
  refused "header" "E1800" (replace "format=1" "format=2");
  refused "no source" "E1800" (replace "source m.jac\n" "");
  refused "two sources" "E1800" (replace "source m.jac" "source m.jac\nsource n.jac");
  refused "repeated name" "E1801" (replace "assumption step" "assumption base");
  refused "result named like an input" "E1801" (replace "result echoed" "result note");
  refused "leading zero" "E1800" (replace "fuel=1000\nresult shifted" "fuel=01000\nresult shifted");
  refused "zero fuel" "E1800" (replace "seed=7 samples=100 fuel=100000" "seed=7 samples=100 fuel=0");
  refused "missing setting" "E1800" (replace "max-branches=10 " "");
  refused "unknown setting" "E1800" (replace "max-branches=10" "max-branches=10 depth=3");
  refused "unknown driver" "E1800"
    (replace "driver run fuel=1000\nresult shifted" "driver gibbs fuel=1000\nresult shifted");
  refused "carriage return" "E1800" (replace "\n" "\r\n");
  refused "bad name" "E1800" (replace "assumption base" "assumption Base");
  refused "no results" "E1800" "jacquard-model format=1\nsource m.jac\nassumption a = 1\n"

let sample_dependency =
  {
    M.entry = Hash.of_string "entry";
    signature = Hash.of_string "sig";
    labels = Some [ Some "rain"; None ];
    prelude = Hash.to_hex (Hash.of_string "prelude");
    core = "0.3.0";
    driver = M.Lw { seed = -3; samples = 20 };
    fuel = 500;
    policy = Hash.of_string "policy";
    arguments =
      [
        M.Assumption (Hash.of_string "a");
        M.Input (Hash.of_string "i");
        M.Term { term = Hash.of_string "t"; signature = Hash.of_string "s" };
      ];
  }

let test_dependency_record () =
  let bytes = M.serialize_dependency sample_dependency in
  (match M.parse_dependency bytes with
  | Ok d -> Alcotest.(check string) "round trip" bytes (M.serialize_dependency d)
  | Error m -> Alcotest.failf "parse failed: %s" m);
  let refused label input =
    Alcotest.(check bool) label true (Result.is_error (M.parse_dependency input))
  in
  let replace a b = Str.global_replace (Str.regexp_string a) b bytes in
  refused "trailing bytes" (bytes ^ "x");
  refused "no final newline" (String.sub bytes 0 (String.length bytes - 1));
  refused "argument count" (replace "arguments 3" "arguments 2");
  refused "argument order" (replace "argument 1 input" "argument 2 input");
  refused "noncanonical seed" (replace "seed=-3" "seed=-03");
  refused "uppercase hash"
    (replace
       (Hash.to_hex (Hash.of_string "a"))
       (String.uppercase_ascii (Hash.to_hex (Hash.of_string "a"))));
  refused "other driver version" (replace "model-driver-v1" "model-driver-v2");
  let k = M.key sample_dependency in
  Alcotest.(check bool)
    "fuel enters the key" false
    (Hash.equal k (M.key { sample_dependency with M.fuel = 501 }));
  Alcotest.(check bool) "the key is domain separated" false (Hash.equal k (Hash.of_string bytes))

let test_prepare () =
  let negative =
    Str.global_replace (Str.regexp_string "helper,5") "helper,-5"
      (Str.global_replace (Str.regexp_string "base = 3") "base = -3" document)
  in
  ignore (prepared ~doc:negative "negative");
  let rs = prepared "base" in
  let get n = List.assoc n rs in
  let world n = (get n).M.world <> [] in
  Alcotest.(check bool) "a pure run needs no grant" false (world "scaled");
  Alcotest.(check bool) "print needs a grant" true (world "greeted");
  Alcotest.(check bool) "lw handles dist" false (world "flip");
  Alcotest.(check bool) "enumerate handles dist" false (world "flip-exact");
  (match (get "applied").M.dependency.M.arguments with
  | [ M.Term _; M.Assumption _ ] -> ()
  | _ -> Alcotest.fail "applied: expected a term and an inline assumption");
  match (get "echoed").M.dependency.M.arguments with
  | [ M.Input h ] ->
      Alcotest.(check string)
        "input identity"
        (Hash.to_hex (Hash.of_string "hello"))
        (Hash.to_hex h)
  | _ -> Alcotest.fail "echoed: expected an input"

(* each edit changes exactly the keys of the results that depend on it *)
let test_invalidation () =
  let base = keys (prepared "inv-base") in
  let changed label expected after =
    Alcotest.(check (list string))
      label expected
      (List.filter_map (fun (n, k) -> if List.assoc n after <> k then Some n else None) base)
  in
  let replace a b = Str.global_replace (Str.regexp_string a) b in
  changed "an unchanged document" [] (keys (prepared "inv-same"));
  changed "assumption step" [ "scaled" ]
    (keys (prepared ~doc:(replace "step = 4" "step = 5" document) "inv-step"));
  changed "a respelled equal assumption" []
    (keys (prepared ~doc:(replace "chance = 0.3" "chance = 0.30" document) "inv-spelling"));
  changed "assumption base" [ "scaled"; "shifted" ]
    (keys (prepared ~doc:(replace "base = 3" "base = 2" document) "inv-base2"));
  changed "a helper only shift reaches" [ "shifted" ]
    (keys (prepared ~src:(replace "add(x, 1)" "add(x, 5)" source) "inv-other"));
  changed "a helper scale and apply reach" [ "scaled"; "applied" ]
    (keys (prepared ~src:(replace "add(x, 2)" "add(x, 7)" source) "inv-helper"));
  changed "an unrelated new definition" []
    (keys (prepared ~src:(source ^ "unused(x) = x\n") "inv-unrelated"));
  changed "the input" [ "echoed"; "greeted" ]
    (keys
       (prepared
          ~files:[ ("other.txt", "bye") ]
          ~doc:(replace "note.txt" "other.txt" document)
          "inv-input"));
  changed "the seed" [ "flip" ]
    (keys (prepared ~doc:(replace "seed=7" "seed=8" document) "inv-seed"));
  changed "a bound" [ "flip-exact" ]
    (keys (prepared ~doc:(replace "max-branches=10" "max-branches=11" document) "inv-bound"));
  let policy =
    match
      Observation_policy.make ~result:Observation_policy.Compare ~field_bytes:64 ~unlisted:None
        ~interface:None []
    with
    | Ok p -> Observation_policy.serialize p
    | Error _ -> Alcotest.fail "policy"
  in
  changed "the policy" (List.map fst base)
    (keys
       (prepared
          ~files:[ ("p.policy", policy) ]
          ~doc:(replace "source m.jac" "source m.jac\npolicy p.policy" document)
          "inv-policy"))

let test_refusals () =
  let replace a b = Str.global_replace (Str.regexp_string a) b document in
  refused "unknown name" "E1802" ~doc:(replace "args base driver" "args nothing driver") ();
  refused "a result as an argument" "E1802"
    ~doc:(replace "args base driver" "args scaled driver")
    ();
  refused "a declared name that is also a term" "E1802"
    ~doc:(replace "assumption step = 4" "assumption step = 4\nassumption echo = 1")
    ();
  refused "a computed assumption" "E1803" ~cause:"computes"
    ~doc:(replace "step = 4" "step = add(1, 3)")
    ();
  refused "an assumption that does not parse" "E1803" ~doc:(replace "step = 4" "step = (") ();
  refused "a sealed constructor" "E1803" ~cause:"sealed constructor"
    ~src:(source ^ "opaque type Token = Token(n: Int)\n")
    ~doc:(replace "step = 4" "step = Token(1)")
    ();
  refused "a missing input" "E1804" ~doc:(replace "note.txt" "absent.txt") ();
  refused "an input that is not UTF-8" "E1804"
    ~files:[ ("bad.txt", "\xff\xfe") ]
    ~doc:(replace "note.txt" "bad.txt") ();
  refused "a malformed policy" "E1804"
    ~files:[ ("p.policy", "nonsense") ]
    ~doc:(replace "source m.jac" "source m.jac\npolicy p.policy")
    ();
  refused "an entry the source does not export" "E1805"
    ~doc:(replace "entry shift" "entry nowhere")
    ();
  refused "an argument of the wrong type" "E1805" ~cause:"does not accept"
    ~doc:(replace "args base driver" "args note driver")
    ()

let suite =
  [
    Alcotest.test_case "model document parse" `Quick test_parse;
    Alcotest.test_case "model document strict parse" `Quick test_parse_refusals;
    Alcotest.test_case "model dependency record" `Quick test_dependency_record;
    Alcotest.test_case "model document prepare" `Quick test_prepare;
    Alcotest.test_case "model key invalidation" `Quick test_invalidation;
    Alcotest.test_case "model document refusals" `Quick test_refusals;
  ]
