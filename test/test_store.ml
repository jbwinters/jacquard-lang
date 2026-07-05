open Jacquard

let fresh_root =
  let n = ref 0 in
  fun () ->
    incr n;
    let dir =
      Filename.concat (Filename.get_temp_dir_name ())
        (Printf.sprintf "jacquard-store-test-%d-%d" (Unix.getpid ()) !n)
    in
    dir

let open_ok root =
  match Store.open_store root with
  | Ok t -> t
  | Error ds ->
      Alcotest.failf "open_store failed: %s" (String.concat "; " (List.map Diag.to_string ds))

let decl_of ~names src =
  match Reader.parse_one ~file:"s.jqd" src with
  | Error _ -> Alcotest.fail "parse failed"
  | Ok f -> (
      match Kernel.decl_of_form f with
      | Error ds ->
          Alcotest.failf "validation failed: %s" (String.concat "; " (List.map Diag.to_string ds))
      | Ok d -> (
          match Resolve.resolve_decl names d with
          | Error ds ->
              Alcotest.failf "resolution failed: %s"
                (String.concat "; " (List.map Diag.to_string ds))
          | Ok d -> d))

let put_ok t d =
  match Store.put_decl t d with
  | Ok hs -> hs
  | Error ds ->
      Alcotest.failf "put_decl failed: %s" (String.concat "; " (List.map Diag.to_string ds))

let read_file = Corpus_support.read_file

(* --- put/get round trip preserves hash identity --- *)

let test_put_get_roundtrip () =
  let t = open_ok (fresh_root ()) in
  let d = decl_of ~names:Resolve.empty_names "(deftype bool () (con false) (con true))" in
  let hs = put_ok t d in
  match Store.get t hs.Canon.decl_hash with
  | Error ds -> Alcotest.failf "get failed: %s" (String.concat "; " (List.map Diag.to_string ds))
  | Ok d' -> (
      match Canon.hash_decl d' with
      | Ok hs' ->
          Alcotest.(check bool)
            "rehash equals original" true
            (Hash.equal hs.Canon.decl_hash hs'.Canon.decl_hash)
      | Error _ -> Alcotest.fail "rehash failed")

let test_get_by_derived_hash () =
  let t = open_ok (fresh_root ()) in
  let d = decl_of ~names:Resolve.empty_names "(deftype bool () (con false) (con true))" in
  let hs = put_ok t d in
  let true_hash = List.assoc "true" hs.Canon.named in
  match Store.locate t true_hash with
  | Ok { Store.role = Store.Constructor 1; decl_hash; _ } ->
      Alcotest.(check bool) "owner is the deftype" true (Hash.equal decl_hash hs.Canon.decl_hash)
  | Ok _ -> Alcotest.fail "expected Constructor 1 role"
  | Error ds -> Alcotest.failf "locate failed: %s" (String.concat "; " (List.map Diag.to_string ds))

let test_names_registered_and_resolvable () =
  let t = open_ok (fresh_root ()) in
  ignore (put_ok t (decl_of ~names:Resolve.empty_names "(deftype bool () (con false) (con true))"));
  ignore
    (put_ok t
       (decl_of ~names:(Store.names_view t)
          "(defterm ((binding not-x () (lam ((pvar b)) (match (var b) (clause (pcon true) (var \
           false)) (clause (pcon false) (var true)))))))"));
  (* the store's names view now resolves both the type's constructors and the new term *)
  match (Store.names_view t).Resolve.lookup "not-x" with
  | [ { Resolve.kind = Resolve.KTerm; _ } ] -> ()
  | _ -> Alcotest.fail "not-x should be a term name in the store index"

(* --- rename touches only names.jqd --- *)

let test_rename_only_names_file () =
  let root = fresh_root () in
  let t = open_ok root in
  let hs =
    put_ok t (decl_of ~names:Resolve.empty_names "(deftype bool () (con false) (con true))")
  in
  let obj =
    Filename.concat (Filename.concat root "objects") (Hash.to_hex hs.Canon.decl_hash ^ ".jqd")
  in
  let before = read_file obj in
  (match Store.rename t ~old_name:"bool" ~new_name:"boolean" () with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "rename failed");
  let after = read_file obj in
  Alcotest.(check string) "object file byte-identical" before after;
  Alcotest.(check bool) "old name gone" true (Store.lookup_name t "bool" = None);
  (match Store.lookup_name t "boolean" with
  | Some { Resolve.hash; _ } ->
      Alcotest.(check bool) "same hash" true (Hash.equal hash hs.Canon.decl_hash)
  | None -> Alcotest.fail "new name missing");
  (* the rename survives a reopen (it is persisted in names.jqd) *)
  let t2 = open_ok root in
  Alcotest.(check bool) "persisted" true (Store.lookup_name t2 "boolean" <> None)

let test_rename_unknown () =
  let t = open_ok (fresh_root ()) in
  match Store.rename t ~old_name:"ghost" ~new_name:"g2" () with
  | Error [ d ] -> Alcotest.(check string) "code" "E0602" d.Diag.code
  | _ -> Alcotest.fail "renaming an unknown name must fail"

(* An invalid new name must be a clean diagnostic and must not damage names.jqd
   (review finding: it used to truncate the index). *)
let test_invalid_names_rejected_safely () =
  let root = fresh_root () in
  let t = open_ok root in
  let hs =
    put_ok t (decl_of ~names:Resolve.empty_names "(deftype bool () (con false) (con true))")
  in
  List.iter
    (fun bad ->
      match Store.rename t ~old_name:"bool" ~new_name:bad () with
      | Error [ d ] -> Alcotest.(check string) (bad ^ " rejected") "E0605" d.Diag.code
      | _ -> Alcotest.failf "rename to %S must fail with E0605" bad)
    [ "Bad"; "a b"; ""; "9x" ];
  (* the index survived: still resolvable in memory and on disk *)
  Alcotest.(check bool) "binding intact" true (Store.lookup_name t "bool" <> None);
  let t2 = open_ok root in
  Alcotest.(check bool) "names.jqd intact" true (Store.lookup_name t2 "bool" <> None);
  match Store.bind_name t "Nope" hs.Canon.decl_hash with
  | Error [ d ] -> Alcotest.(check string) "bind invalid name" "E0605" d.Diag.code
  | _ -> Alcotest.fail "bind_name with invalid name must fail"

let test_defterm_group_hash_not_nameable () =
  let t = open_ok (fresh_root ()) in
  let hs = put_ok t (decl_of ~names:Resolve.empty_names "(defterm ((binding one () (lit 1))))") in
  match Store.bind_name t "the-group" hs.Canon.decl_hash with
  | Error [ d ] -> Alcotest.(check string) "code" "E0604" d.Diag.code
  | _ -> Alcotest.fail "naming a defterm group hash must fail"

(* --- deps and dependents --- *)

(* A 3-decl chain: c-three depends on b-two depends on a-one. *)
let test_deps_chain () =
  let t = open_ok (fresh_root ()) in
  let put src = put_ok t (decl_of ~names:(Store.names_view t) src) in
  let a = put "(defterm ((binding a-one () (lit 1))))" in
  let b = put "(defterm ((binding b-two () (app (var a-one)))))" in
  let c = put "(defterm ((binding c-three () (app (var b-two)))))" in
  let a_member = List.assoc "a-one" a.Canon.named in
  let b_member = List.assoc "b-two" b.Canon.named in
  let deps h =
    match Store.deps t h with
    | Ok l -> l
    | Error ds -> Alcotest.failf "deps failed: %s" (String.concat "; " (List.map Diag.to_string ds))
  in
  Alcotest.(check bool) "a has no deps" true (deps a.Canon.decl_hash = []);
  Alcotest.(check bool)
    "b depends on a's member" true
    (List.exists (Hash.equal a_member) (deps b.Canon.decl_hash));
  Alcotest.(check bool)
    "c depends on b's member" true
    (List.exists (Hash.equal b_member) (deps c.Canon.decl_hash));
  Alcotest.(check bool)
    "c does not depend on a directly" false
    (List.exists (Hash.equal a_member) (deps c.Canon.decl_hash));
  let dependents h =
    match Store.dependents t h with Ok l -> l | Error _ -> Alcotest.fail "dependents failed"
  in
  Alcotest.(check bool) "a's dependents = {b}" true (dependents a_member = [ b.Canon.decl_hash ]);
  Alcotest.(check bool) "b's dependents = {c}" true (dependents b_member = [ c.Canon.decl_hash ])

let take_targets pool fanout =
  let rec go n = function [] -> [] | x :: rest -> if n <= 0 then [] else x :: go (n - 1) rest in
  go fanout pool

(* dependents is the inverse of deps, on random DAGs *)
let prop_dependents_inverse_of_deps =
  QCheck.Test.make ~count:25 ~name:"dependents inverse of deps (random DAGs)"
    QCheck.(make Gen.(list_size (int_range 1 8) (int_bound 2)))
    (fun fanouts ->
      let t = open_ok (fresh_root ()) in
      (* node i references up to fanouts[i] earlier members *)
      let members = ref [] in
      List.iteri
        (fun i fanout ->
          let targets = take_targets !members fanout in
          let body =
            match targets with
            | [] -> "(lit 1)"
            | ts ->
                "(tuple " ^ String.concat " " (List.map (fun n -> "(app (var " ^ n ^ "))") ts) ^ ")"
          in
          let name = Printf.sprintf "node-%d" i in
          let src = Printf.sprintf "(defterm ((binding %s () %s)))" name body in
          ignore (put_ok t (decl_of ~names:(Store.names_view t) src));
          members := name :: !members)
        fanouts;
      (* check the inverse property over every stored decl *)
      let decls =
        List.filter_map
          (fun (n, _) ->
            match Store.lookup_name t n with
            | Some { Resolve.hash; _ } -> (
                match Store.locate t hash with Ok l -> Some l.Store.decl_hash | Error _ -> None)
            | None -> None)
          (List.map (fun n -> (n, ())) !members)
      in
      List.for_all
        (fun dh ->
          match Store.deps t dh with
          | Error _ -> false
          | Ok ds ->
              List.for_all
                (fun d ->
                  match Store.dependents t d with
                  | Error _ -> false
                  | Ok back -> List.exists (Hash.equal dh) back)
                ds)
        (List.sort_uniq Hash.compare decls))

(* --- reopening rebuilds the index --- *)

let test_reopen_rebuilds_index () =
  let root = fresh_root () in
  let hs =
    let t = open_ok root in
    put_ok t (decl_of ~names:Resolve.empty_names "(deftype bool () (con false) (con true))")
  in
  let t2 = open_ok root in
  match Store.locate t2 (List.assoc "true" hs.Canon.named) with
  | Ok { Store.role = Store.Constructor 1; _ } -> ()
  | _ -> Alcotest.fail "derived hash index must survive reopen"

let test_unknown_hash () =
  let t = open_ok (fresh_root ()) in
  match Store.get t (Hash.of_string "nothing") with
  | Error [ d ] -> Alcotest.(check string) "code" "E0601" d.Diag.code
  | _ -> Alcotest.fail "unknown hash must fail"

(* PV.1: origin sidecars — stamped, carried through reopen, never hash-relevant,
   corrupt = ignored-with-warning *)
let test_origin_roundtrip () =
  let root = fresh_root () in
  let t = open_ok root in
  let d = decl_of ~names:Resolve.empty_names "(deftype bool () (con false) (con true))" in
  let hs =
    match Store.put_decl ~origin:"agent:jacquard-demo-5" t d with
    | Ok hs -> hs
    | Error ds -> Alcotest.failf "put: %s" (String.concat "; " (List.map Diag.to_string ds))
  in
  Alcotest.(check (option string))
    "read back" (Some "agent:jacquard-demo-5")
    (Store.origin t hs.Canon.decl_hash);
  Alcotest.(check (option string))
    "derived hash resolves to the owner's origin" (Some "agent:jacquard-demo-5")
    (Store.origin t (List.assoc "true" hs.Canon.named));
  (* survives reopen; the identity self-check ignores sidecars *)
  let t2 = open_ok root in
  Alcotest.(check (option string))
    "persisted" (Some "agent:jacquard-demo-5")
    (Store.origin t2 hs.Canon.decl_hash);
  (* unstamped is a clean absence *)
  let d2 = decl_of ~names:(Store.names_view t2) "(defterm ((binding quiet () (lit 1))))" in
  let hs2 = put_ok t2 d2 in
  Alcotest.(check (option string))
    "absence is not an error" None
    (Store.origin t2 hs2.Canon.decl_hash);
  (* corrupt sidecar: ignored, store still opens *)
  let oc =
    open_out_bin
      (Filename.concat (Filename.concat root "objects")
         (Hash.to_hex hs.Canon.decl_hash ^ ".origin"))
  in
  output_string oc "";
  close_out oc;
  let t3 = open_ok root in
  Alcotest.(check (option string)) "empty sidecar ignored" None (Store.origin t3 hs.Canon.decl_hash)

let suite =
  [
    Alcotest.test_case "put/get round trip preserves hash" `Quick test_put_get_roundtrip;
    Alcotest.test_case "origin sidecar roundtrip" `Quick test_origin_roundtrip;
    Alcotest.test_case "get by derived hash" `Quick test_get_by_derived_hash;
    Alcotest.test_case "names registered and resolvable" `Quick test_names_registered_and_resolvable;
    Alcotest.test_case "rename touches only names.jqd" `Quick test_rename_only_names_file;
    Alcotest.test_case "rename unknown name" `Quick test_rename_unknown;
    Alcotest.test_case "invalid names rejected safely" `Quick test_invalid_names_rejected_safely;
    Alcotest.test_case "defterm group hash not nameable" `Quick test_defterm_group_hash_not_nameable;
    Alcotest.test_case "deps on a 3-decl chain" `Quick test_deps_chain;
    QCheck_alcotest.to_alcotest prop_dependents_inverse_of_deps;
    Alcotest.test_case "reopen rebuilds index" `Quick test_reopen_rebuilds_index;
    Alcotest.test_case "unknown hash" `Quick test_unknown_hash;
  ]
