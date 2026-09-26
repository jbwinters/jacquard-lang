(* PKG.1: pinning rechecks every file it read (design §8). *)

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

let fresh_dir =
  let serial = ref 0 in
  fun label ->
    incr serial;
    let dir =
      Filename.concat (Filename.get_temp_dir_name ())
        (Printf.sprintf "jacquard-project-%s-%d-%d" label (Unix.getpid ()) !serial)
    in
    at_exit (fun () -> try remove_tree dir with Unix.Unix_error _ | Sys_error _ -> ());
    dir

let write path contents = Out_channel.with_open_bin path (fun oc -> output_string oc contents)
let read path = In_channel.with_open_bin path In_channel.input_all

(* a library and an application that depends on it, unpinned *)
let graph () =
  let dir = fresh_dir "pin" in
  List.iter
    (fun d -> Unix.mkdir d 0o755)
    [ dir; Filename.concat dir "lib"; Filename.concat dir "app" ];
  Unix.mkdir (Filename.concat dir ".git") 0o755;
  write
    (Filename.concat dir "lib/project.jqd")
    "(project-v1 (name \"lib\") (requires (core \"0.2\")) (namespace lib) (units \"l.jac\") \
     (exports (term lib.one)))";
  write (Filename.concat dir "lib/l.jac") "lib.one() = 1\n";
  write
    (Filename.concat dir "app/project.jqd")
    "(project-v1 (name \"app\") (requires (core \"0.2\")) (deps (dep (as l) (path \"../lib\"))))";
  Filename.concat dir "app/project.jqd"

let open_pinning manifest =
  expect_ok "open graph"
    (Project_frontend.open_graph ~pinning:true ~prelude_dir ~root:(fresh_dir "store") manifest)

let test_pin_writes () =
  let manifest = graph () in
  let session, node = open_pinning manifest in
  let plans = expect_ok "plan" (Project_frontend.plan_pins session node ~only:[]) in
  expect_ok "write" (Project_frontend.write_pins session node plans);
  let pinned = expect_ok "reread" (Project_manifest.read manifest) in
  Alcotest.(check bool)
    "the pin is the dependency's context identity" true
    (List.for_all
       (fun (d : Project_manifest.dep) -> d.pin = Some (List.hd plans).Project_frontend.new_pin)
       pinned.deps);
  (* a second pass over the pinned graph finds nothing to change *)
  let session, node =
    expect_ok "reopen" (Project_frontend.open_graph ~prelude_dir ~root:(fresh_dir "store") manifest)
  in
  let again = expect_ok "replan" (Project_frontend.plan_pins session node ~only:[]) in
  Alcotest.(check bool)
    "pins are stable" true
    (List.for_all (fun (p : Project_frontend.pin_plan) -> p.old_pin = Some p.new_pin) again)

let test_concurrent_edit () =
  let manifest = graph () in
  let session, node = open_pinning manifest in
  let plans = expect_ok "plan" (Project_frontend.plan_pins session node ~only:[]) in
  let before = read manifest in
  (* a unit of the dependency changes between reading and writing *)
  write
    (Filename.concat (Filename.dirname (Filename.dirname manifest)) "lib/l.jac")
    "lib.one() = 2\n";
  (match Project_frontend.write_pins session node plans with
  | Ok () -> Alcotest.fail "a changed source must stop the pin"
  | Error ds ->
      Alcotest.(check (list (option string))) "E1733" [ Some "E1733" ] (List.map Diag.code ds));
  Alcotest.(check string) "the manifest is untouched" before (read manifest);
  Alcotest.(check bool)
    "no pin records were written" false
    (Sys.file_exists (Filename.concat (Filename.dirname manifest) ".jacquard"))

let suite =
  [
    Alcotest.test_case "pin writes stable context identities" `Quick test_pin_writes;
    Alcotest.test_case "a file changed while pinning stops the pin (E1733)" `Quick
      test_concurrent_edit;
  ]
