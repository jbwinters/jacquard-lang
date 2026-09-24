(* API.1: interface manifests, their identity, comparison, and import validation. *)

open Jacquard

let prelude_dir = "../prelude"
let fail_diagnostics diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let expect_ok label = function
  | Ok value -> value
  | Error diagnostics -> Alcotest.failf "%s failed:\n%s" label (fail_diagnostics diagnostics)

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let fresh_root =
  let serial = ref 0 in
  fun label ->
    incr serial;
    let root =
      Filename.concat (Filename.get_temp_dir_name ())
        (Printf.sprintf "jacquard-interface-%s-%d-%d" label (Unix.getpid ()) !serial)
    in
    at_exit (fun () -> try remove_tree root with Unix.Unix_error _ | Sys_error _ -> ());
    root

let library =
  "type Pair a b = | MkPair(left: a, right: b)\n\
   type Reply = | Accepted(value: Int) | Refused(reason: Text)\n\
   resize(image, scale: ratio) = (image, ratio)\n\
   once effect Sending where { send : (path: Text, body: Text) -> Text }\n\
   swap(p) = match p { | MkPair(left: l, right: r) -> MkPair(r, l) }\n"

let checked ?(file = "lib.jac") source =
  match
    Frontend.check ~prelude_dir ~root:(fresh_root "check") ~syntax:Frontend.Auto ~file source
  with
  | Ok (Frontend.Checked artifact) -> artifact
  | Ok (Frontend.Recovered _) -> Alcotest.fail "a strict source produced a recovery report"
  | Error diagnostics -> Alcotest.failf "check failed:\n%s" (fail_diagnostics diagnostics)

let interface_of ?file source = Frontend.Checked.interface (checked ?file source)
let hex = Hash.to_hex

let session label =
  fst (expect_ok "open session" (Frontend.open_session ~prelude_dir ~root:(fresh_root label)))

let refusal =
  Diag.error ~domain:Diag.Process ~code:"E0704" ~summary:"refused" ~cause:"refused"
    ~next_step:"none" ~contrast:None ()

let install ?(syntax = Frontend.Auto) ?(file = "lib.jac") store source =
  expect_ok "install"
    (Frontend.install_declarations ~expression_refusal:refusal ~syntax store ~file source)

(* The positional [.jqd] twin of a checked source, as [jac export] would write it. *)
let exported_twin artifact =
  Printer.print_all
    (List.map
       (fun (top : Frontend.Checked.top) -> Kernel.to_form top.resolved)
       (Frontend.Checked.tops artifact))

let names manifest = List.map (fun export -> export.Interface.name) manifest.Interface.exports

let test_rename_and_reformat_stability () =
  let original = interface_of library in
  (* binder renames and whitespace changes leave every export and the identity untouched *)
  let reformatted =
    interface_of
      "type Pair a b = | MkPair(left: a, right: b)\n\n\
       type Reply = | Accepted(value: Int) | Refused(reason: Text)\n\
       resize(img, scale: r) = (img, r)\n\
       once effect Sending where { send : (path: Text, body: Text) -> Text }\n\
       swap(q) = match q {\n\
      \  | MkPair(left: l, right: r) -> MkPair(r,  l)\n\
       }\n"
  in
  Alcotest.(check bool) "exports equal" true (original.exports = reformatted.exports);
  Alcotest.(check bool) "hidden equal" true (original.hidden = reformatted.hidden);
  Alcotest.(check string)
    "identity equal"
    (hex (Interface.identity original))
    (hex (Interface.identity reformatted));
  Alcotest.(check bool) "source digests differ" true (original.source <> reformatted.source);
  Alcotest.(check (list string))
    "exports sorted by name"
    [
      "accepted";
      "mk-pair";
      "pair";
      "pair.left";
      "pair.right";
      "refused";
      "reply";
      "resize";
      "send";
      "sending";
      "swap";
    ]
    (names original);
  let report = Interface.diff ~old:original ~new_:reformatted in
  Alcotest.(check bool) "no API change" true (report.Interface.entries = []);
  (* a public rename keeps the identity but is not compatible for importers by name *)
  let renamed = interface_of (Str.global_replace (Str.regexp_string "resize") "rescale" library) in
  (match Interface.diff ~old:original ~new_:renamed with
  | {
   Interface.compatible = false;
   entries = [ ({ Interface.name = "rescale"; _ }, [ Interface.Renamed_from "resize" ]) ];
  } ->
      ()
  | report ->
      Alcotest.failf "rename reported as: %s"
        (Option.value (Interface.render_report report) ~default:"<nothing>"));
  (* signatures are name-independent: the type is spelled by its hash *)
  let swap = Option.get (Interface.find original "swap" Resolve.KTerm) in
  let pair = Option.get (Interface.find original "pair" Resolve.KType) in
  Alcotest.(check bool)
    "signature spells identities as hashes" true
    (let needle = "#" ^ hex pair.hash in
     let text = Option.get swap.signature in
     let n = String.length needle in
     let rec scan i =
       i + n <= String.length text && (String.sub text i n = needle || scan (i + 1))
     in
     scan 0)

let test_change_detection () =
  let original = interface_of library in
  let variant replacement =
    interface_of (Str.global_replace (Str.regexp_string "scale: ratio") replacement library)
  in
  let expect label ~compatible expected report =
    Alcotest.(check bool) (label ^ " compatible") compatible report.Interface.compatible;
    Alcotest.(check (list string))
      (label ^ " entries") expected
      (List.map
         (fun (export, changes) ->
           export.Interface.name ^ ":"
           ^ String.concat ","
               (List.map
                  (function
                    | Interface.Added -> "added"
                    | Removed -> "removed"
                    | Renamed_from _ -> "renamed"
                    | Identity_changed _ -> "identity"
                    | Signature_changed_to _ -> "signature"
                    | Labels_changed _ -> "labels"
                    | Mode_changed _ -> "mode"
                    | Arity_changed _ -> "arity"
                    | Became_hidden -> "hidden"
                    | Became_public -> "public")
                  changes))
         report.Interface.entries)
  in
  expect "label change" ~compatible:false [ "resize:labels" ]
    (Interface.diff ~old:original ~new_:(variant "factor: ratio"));
  expect "signature change" ~compatible:false [ "resize:identity,signature" ]
    (Interface.diff ~old:original
       ~new_:
         (interface_of
            (Str.global_replace (Str.regexp_string "(image, ratio)") "(ratio, image)" library)));
  expect "addition" ~compatible:true [ "extra:added" ]
    (Interface.diff ~old:original ~new_:(interface_of (library ^ "extra = 1\n")));
  expect "removal" ~compatible:false [ "swap:removed" ]
    (Interface.diff ~old:original
       ~new_:(interface_of (Str.global_replace (Str.regexp "swap(p).*\n") "" library)));
  (* the mode is identity-bearing, so the owning effect's identity moves too *)
  expect "mode change" ~compatible:false
    [ "send:identity,signature,mode"; "sending:identity" ]
    (Interface.diff ~old:original
       ~new_:
         (interface_of
            (Str.global_replace (Str.regexp_string "once effect") "multi effect" library)));
  expect "arity change" ~compatible:false
    [
      "mk-pair:identity,signature";
      "pair:identity,arity";
      "pair.left:identity,signature";
      "pair.right:identity,signature";
      "swap:identity,signature";
    ]
    (Interface.diff ~old:original
       ~new_:
         (interface_of
            (Str.global_replace
               (Str.regexp_string "Pair a b = | MkPair(left: a, right: b)")
               "Pair a = | MkPair(left: a, right: a)" library)));
  Alcotest.(check bool)
    "identical manifests render nothing" true
    (Interface.render_report (Interface.diff ~old:original ~new_:original) = None);
  (* an alias shares an identity with a surviving name: adding or removing it is not a rename *)
  let single = interface_of "a = 1\n" and aliased = interface_of "a = 1\nb = 1\n" in
  expect "alias added" ~compatible:true [ "b:added" ] (Interface.diff ~old:single ~new_:aliased);
  expect "alias removed" ~compatible:false [ "b:removed" ]
    (Interface.diff ~old:aliased ~new_:single);
  expect "alias renamed" ~compatible:false [ "c:renamed" ]
    (Interface.diff ~old:aliased ~new_:(interface_of "a = 1\nc = 1\n"));
  (* each rename consumes one removed and one added name; the rest are reported on their own *)
  expect "one rename, one removal" ~compatible:false [ "c:renamed"; "b:removed" ]
    (Interface.diff ~old:aliased ~new_:(interface_of "c = 1\n"));
  expect "one rename, one addition" ~compatible:false [ "c:renamed"; "d:added" ]
    (Interface.diff ~old:single ~new_:(interface_of "c = 1\nd = 1\n"))

let test_visibility () =
  (* hiding a constructor turns its export into a recorded hidden member; exposing reverses it *)
  let store = session "visibility" in
  let declarations, _ =
    expect_ok "resolve"
      (Frontend.resolve_source_tops ~syntax:Frontend.Auto store ~file:"lib.jac"
         "type Probability = | MkProbability(value: Real)\nmk(x) = MkProbability(x)\n")
  in
  let declarations =
    List.filter_map
      (function
        | Kernel.Decl declaration ->
            Some (declaration, expect_ok "hash" (Canon.hash_top (Kernel.Decl declaration)))
        | Kernel.Expr _ -> None)
      declarations
  in
  let checker = expect_ok "checker" (Frontend.make_checker store) in
  let manifest () =
    expect_ok "manifest" (Interface.of_side checker (Diff.source_side store declarations))
  in
  let public = manifest () in
  let constructor = Option.get (Interface.find public "mk-probability" Resolve.KCon) in
  Alcotest.(check bool)
    "constructor public" true
    (Interface.member_visibility public constructor.hash = Some Interface.Public);
  Alcotest.(check bool) "no hidden members" true (public.hidden = []);
  Store.hide_derived store constructor.hash;
  let abstract = manifest () in
  Alcotest.(check bool)
    "constructor hidden" true
    (Interface.member_visibility abstract constructor.hash = Some Interface.Hidden);
  Alcotest.(check bool)
    "hidden member names its owner" true
    (abstract.hidden = [ (constructor.hash, constructor.owner) ]);
  Alcotest.(check bool)
    "smart constructor still exported" true
    (Interface.find abstract "mk" Resolve.KTerm <> None);
  (match Interface.diff ~old:public ~new_:abstract with
  | {
   Interface.compatible = false;
   entries = [ ({ Interface.name = "mk-probability"; _ }, [ Interface.Became_hidden ]) ];
  } ->
      ()
  | report ->
      Alcotest.failf "hiding reported as: %s"
        (Option.value (Interface.render_report report) ~default:"<nothing>"));
  (match Interface.diff ~old:abstract ~new_:public with
  | { Interface.compatible = true; entries = [ (_, [ Interface.Became_public ]) ] } -> ()
  | report ->
      Alcotest.failf "exposing reported as: %s"
        (Option.value (Interface.render_report report) ~default:"<nothing>"));
  (* a provider that publicly binds a member this API hides is refused on import *)
  Alcotest.(check bool) "abstract manifest verifies" true (Interface.verify abstract store = Ok ());
  let exposing = session "exposing" in
  install exposing "type Probability = | MkProbability(value: Real)\nmk(x) = MkProbability(x)\n";
  match Interface.verify abstract exposing with
  | Error [ Interface.Exposed hash ] ->
      Alcotest.(check string) "exposed member" (hex constructor.hash) (hex hash)
  | Error mismatches ->
      Alcotest.failf "unexpected mismatches: %s"
        (String.concat "; " (List.map Interface.describe_mismatch mismatches))
  | Ok () -> Alcotest.fail "an exposed hidden member verified"

let test_round_trip () =
  let manifest = interface_of library in
  let text = Interface.serialize manifest in
  let parsed = expect_ok "parse" (Interface.parse ~file:"lib.jqi" text) in
  Alcotest.(check bool) "parse recovers the manifest" true (parsed = manifest);
  Alcotest.(check string) "serialize is idempotent" text (Interface.serialize parsed);
  Alcotest.(check string)
    "identity survives"
    (hex (Interface.identity manifest))
    (hex (Interface.identity parsed));
  Alcotest.(check bool)
    "version header first" true
    (String.starts_with ~prefix:"(interface-v1" text);
  let refused label input =
    match Interface.parse ~file:"bad.jqi" input with
    | Error (diagnostic :: _) ->
        Alcotest.(check string) label "E0613" (Diag.code_or_uncoded diagnostic)
    | Error [] -> Alcotest.failf "%s: refused without a diagnostic" label
    | Ok _ -> Alcotest.failf "%s: accepted" label
  in
  refused "empty" "";
  refused "wrong header" "(interface-v2 (hash-algorithm \"HASH_V0\"))\n";
  refused "wrong algorithm" "(interface-v1 (hash-algorithm \"SHA1\"))\n";
  refused "unknown form" "(interface-v1 (hash-algorithm \"HASH_V0\"))\n(mystery 1)\n";
  refused "bad slot"
    "(interface-v1 (hash-algorithm \"HASH_V0\"))\n\
     (export term f #0000000000000000000000000000000000000000000000000000000000000000 (owner \
     #0000000000000000000000000000000000000000000000000000000000000000) (labels (slot sideways)))\n"

let test_import_validation () =
  let artifact = checked library in
  let manifest = Frontend.Checked.interface artifact in
  (* the same declarations in another session provide the interface exactly *)
  let store = session "provider" in
  install store library;
  Alcotest.(check bool) "provided" true (Interface.verify manifest store = Ok ());
  let mismatches label store =
    match Interface.verify manifest store with
    | Ok () -> Alcotest.failf "%s: verified" label
    | Error mismatches -> List.map Interface.describe_mismatch mismatches
  in
  let has label needle found =
    Alcotest.(check bool)
      (label ^ ": " ^ needle)
      true
      (List.exists
         (fun text ->
           let n = String.length needle in
           let rec scan i =
             i + n <= String.length text && (String.sub text i n = needle || scan (i + 1))
           in
           scan 0)
         found)
  in
  (* the positional export carries the same identities but no companions: labels are never inferred *)
  let positional = session "positional" in
  install ~syntax:Frontend.Bootstrap ~file:"lib.jqd" positional (exported_twin artifact);
  let found = mismatches "positional twin" positional in
  has "positional twin" "term resize carries no call-abi-v1 companion" found;
  has "positional twin" "op send carries no call-abi-v1 companion" found;
  Alcotest.(check int) "only the two companions are missing" 2 (List.length found);
  (* a different label vector for the same hash *)
  let relabeled = session "relabeled" in
  install relabeled (Str.global_replace (Str.regexp_string "scale: ratio") "factor: ratio" library);
  has "relabeled" "term resize carries labels (positional, factor:), not (positional, scale:)"
    (mismatches "relabeled" relabeled);
  (* a missing export and a rebound one *)
  let partial = session "partial" in
  install partial
    (Str.global_replace (Str.regexp "swap(p).*\n") "resize(image, scale: ratio) = (ratio, image)\n"
       (Str.global_replace
          (Str.regexp_string "resize(image, scale: ratio) = (image, ratio)\n")
          "" library));
  let found = mismatches "partial" partial in
  has "partial" "term swap is not bound" found;
  has "partial" "term resize is bound to" found;
  (* a store loaded with a different prelude *)
  let bare = expect_ok "bare store" (Store.open_store (fresh_root "bare")) in
  Alcotest.(check bool)
    "bare store lacks everything" true
    (List.length (mismatches "bare" bare) >= List.length manifest.exports);
  (* positional-only programs need no companion and verify against their exported twin *)
  let plain = checked "add3(a, b, c) = add(add(a, b), c)\ntype Box a = | Box a\n" in
  let twin = session "plain-twin" in
  install ~syntax:Frontend.Bootstrap ~file:"plain.jqd" twin (exported_twin plain);
  let plain_manifest = Frontend.Checked.interface plain in
  Alcotest.(check bool)
    "positional terms record no labels" true
    ((Option.get (Interface.find plain_manifest "add3" Resolve.KTerm)).labels = None);
  Alcotest.(check bool)
    "positional twin provides the interface" true
    (Interface.verify plain_manifest twin = Ok ());
  (* a source that rebinds a prelude name still verifies against its own provider *)
  let rebinding = "x = 1\ntype Int = | Other\neq(a, b) = 1\n" in
  let rebound_manifest = interface_of rebinding in
  let provider = session "rebinding" in
  install provider rebinding;
  Alcotest.(check bool)
    "prelude redefinitions are portable" true
    (Interface.verify rebound_manifest provider = Ok ());
  (* recorded contracts are checked against the declaration, not trusted *)
  let tampered what edit =
    let text = Interface.serialize manifest in
    let edited = Str.replace_first (Str.regexp_string what) edit text in
    Alcotest.(check bool) ("tampered " ^ what ^ " differs") true (edited <> text);
    match
      Interface.verify (expect_ok "parse tampered" (Interface.parse ~file:"t.jqi" edited)) store
    with
    | Error mismatches ->
        Alcotest.(check bool)
          ("tampered " ^ what ^ " refused as a declaration mismatch")
          true
          (List.exists
             (function Interface.Declaration_mismatch _ -> true | _ -> false)
             mismatches)
    | Ok () -> Alcotest.failf "tampered %s verified" what
  in
  tampered "(slot named left)" "(slot named nonexistent)";
  tampered "(mode once)" "(mode multi)";
  tampered "(arity 2)" "(arity 9)";
  let owner_line =
    "(owner #" ^ hex (Option.get (Interface.find manifest "swap" Resolve.KTerm)).owner ^ ")"
  in
  tampered owner_line ("(owner #" ^ String.make 64 '0' ^ ")")

let test_source_store_portability () =
  (* the manifest sealed by check equals the one derived from a store the declarations were
     installed in, so a pin made from source can be validated against any provider *)
  let artifact = checked library in
  let sealed = Frontend.Checked.interface artifact in
  let store = session "portable" in
  let tops, _ =
    expect_ok "resolve"
      (Frontend.resolve_source_tops ~syntax:Frontend.Auto store ~file:"lib.jac" library)
  in
  let declarations =
    List.filter_map
      (function
        | Kernel.Decl declaration ->
            Some (declaration, expect_ok "hash" (Canon.hash_top (Kernel.Decl declaration)))
        | Kernel.Expr _ -> None)
      tops
  in
  let checker = expect_ok "checker" (Frontend.make_checker store) in
  let derived =
    expect_ok "derive" (Interface.of_side checker (Diff.source_side store declarations))
  in
  Alcotest.(check bool) "exports agree" true (sealed.exports = derived.exports);
  Alcotest.(check bool) "hidden agree" true (sealed.hidden = derived.hidden);
  Alcotest.(check bool) "prelude agrees" true (sealed.prelude = derived.prelude);
  Alcotest.(check string)
    "identity agrees"
    (hex (Interface.identity sealed))
    (hex (Interface.identity derived));
  Alcotest.(check bool)
    "source recorded only for the sealed one" true
    (sealed.source <> None && derived.source = None);
  (* the scheduler carrier's private constructor is a hidden member, never an export *)
  let carrier = interface_of "type ChannelHandle a = | ChannelOpaque\n" in
  Alcotest.(check (list string))
    "carrier exports its type only" [ "channel-handle" ] (names carrier);
  Alcotest.(check int) "carrier hides its constructor" 1 (List.length carrier.hidden)

let suite =
  [
    Alcotest.test_case "renames and reformatting keep the interface identity" `Quick
      test_rename_and_reformat_stability;
    Alcotest.test_case "label, signature, mode, arity, and membership changes are detected" `Quick
      test_change_detection;
    Alcotest.test_case "hidden members are recorded, compared, and enforced" `Quick test_visibility;
    Alcotest.test_case "serialization round-trips deterministically and refuses damage" `Quick
      test_round_trip;
    Alcotest.test_case "import validation refuses missing or mismatched companions" `Quick
      test_import_validation;
    Alcotest.test_case "source and store derivations agree" `Quick test_source_store_portability;
  ]
