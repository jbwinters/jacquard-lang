open Jacquard

let write path contents =
  let channel = open_out_bin path in
  output_string channel contents;
  close_out channel

let read path =
  let channel = open_in_bin path in
  let contents = really_input_string channel (in_channel_length channel) in
  close_in channel;
  contents

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun child -> remove_tree (Filename.concat path child)) (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
      Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_dir name body =
  let root =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-export-%s-%d" name (Unix.getpid ()))
  in
  remove_tree root;
  Unix.mkdir root 0o755;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> body root)

let temp_files root output =
  let prefix = "." ^ Filename.basename output ^ ".tmp-" in
  Sys.readdir root |> Array.to_list |> List.filter (String.starts_with ~prefix)

let fail point = raise (Unix.Unix_error (Unix.EIO, "injected", point))

let test_input_descriptor_is_stable () =
  with_dir "input-race" (fun root ->
      let original = Filename.concat root "original.jac" in
      let replacement = Filename.concat root "replacement.jac" in
      let source = Filename.concat root "source.jac" in
      write original "original\n";
      write replacement "replacement\n";
      Unix.symlink "original.jac" source;
      let result =
        Export.For_test.read_regular_file source ~after_open:(fun () ->
            Unix.unlink source;
            Unix.symlink "replacement.jac" source)
      in
      Alcotest.(check (result string string))
        "opened descriptor wins" (Ok "original\n")
        (Result.map_error
           (function
             | Export.Stdin -> "stdin"
             | Export.Not_regular -> "not regular"
             | Export.Read_failure message -> message)
           result))

let test_fifo_is_rejected_without_blocking () =
  with_dir "fifo" (fun root ->
      let fifo = Filename.concat root "source.fifo" in
      Unix.mkfifo fifo 0o600;
      match Export.read_regular_file fifo with
      | Error Export.Not_regular -> ()
      | Error Export.Stdin -> Alcotest.fail "FIFO reported as stdin"
      | Error (Export.Read_failure message) -> Alcotest.fail message
      | Ok _ -> Alcotest.fail "FIFO was read as a regular source")

let test_atomic_success_and_collision () =
  with_dir "success" (fun root ->
      let output = Filename.concat root "out.jqd" in
      Alcotest.(check bool)
        "first publish" true
        (Result.is_ok (Export.write_atomic_exclusive ~path:output "first\n"));
      Alcotest.(check string) "published bytes" "first\n" (read output);
      (match Export.write_atomic_exclusive ~path:output "second\n" with
      | Error Export.Collision -> ()
      | Error (Export.Atomic_failure message) -> Alcotest.fail message
      | Ok () -> Alcotest.fail "collision replaced the output");
      Alcotest.(check string) "collision preserved bytes" "first\n" (read output);
      let cleanup_failed = ref false in
      let fault = function
        | Export.For_test.Temp_cleanup when not !cleanup_failed ->
            cleanup_failed := true;
            fail "collision-cleanup"
        | _ -> ()
      in
      (match Export.For_test.write_atomic_exclusive ~fault ~path:output "third\n" with
      | Error (Export.Atomic_failure message) ->
          Alcotest.(check bool)
            "collision cleanup failure named" true
            (String.starts_with ~prefix:"destination collision; cleanup failed:" message)
      | Error Export.Collision -> Alcotest.fail "cleanup fault was hidden behind collision"
      | Ok () -> Alcotest.fail "collision cleanup failure reported success");
      Alcotest.(check string) "faulted collision preserved bytes" "first\n" (read output);
      Alcotest.(check (list string)) "no temporary" [] (temp_files root output))

let test_parent_sync_failure_rolls_back () =
  with_dir "sync-rollback" (fun root ->
      List.iter
        (fun (label, failed_point) ->
          let output = Filename.concat root (label ^ ".jqd") in
          let fault point = if point = failed_point then fail label in
          (match Export.For_test.write_atomic_exclusive ~fault ~path:output "bytes\n" with
          | Error (Export.Atomic_failure _) -> ()
          | Error Export.Collision -> Alcotest.fail "unexpected collision"
          | Ok () -> Alcotest.fail "parent sync failure reported success");
          Alcotest.(check bool) (label ^ " destination rolled back") false (Sys.file_exists output);
          Alcotest.(check (list string))
            (label ^ " temporary rolled back")
            [] (temp_files root output))
        [
          ("after-link", Export.For_test.Parent_sync_after_link);
          ("after-cleanup", Export.For_test.Parent_sync_after_cleanup);
        ])

let test_cleanup_failure_is_retried_and_reported () =
  with_dir "cleanup-retry" (fun root ->
      let output = Filename.concat root "out.jqd" in
      let failed = ref false in
      let fault = function
        | Export.For_test.Temp_cleanup when not !failed ->
            failed := true;
            fail "temp-cleanup"
        | _ -> ()
      in
      (match Export.For_test.write_atomic_exclusive ~fault ~path:output "bytes\n" with
      | Error (Export.Atomic_failure message) ->
          Alcotest.(check bool)
            "cleanup named" true
            (String.starts_with ~prefix:"temporary cleanup failed" message)
      | Error Export.Collision -> Alcotest.fail "unexpected collision"
      | Ok () -> Alcotest.fail "temporary cleanup failure reported success");
      Alcotest.(check bool) "destination rolled back" false (Sys.file_exists output);
      Alcotest.(check (list string)) "retry removed temporary" [] (temp_files root output))

let test_persistent_cleanup_failure_is_diagnosed () =
  with_dir "cleanup-persistent" (fun root ->
      let output = Filename.concat root "out.jqd" in
      let fault = function
        | Export.For_test.Temp_cleanup | Export.For_test.Temp_rollback -> fail "temp-cleanup"
        | _ -> ()
      in
      (match Export.For_test.write_atomic_exclusive ~fault ~path:output "bytes\n" with
      | Error (Export.Atomic_failure message) ->
          Alcotest.(check bool)
            "rollback cleanup named" true
            (String.contains message ';' && String.ends_with ~suffix:"temp-cleanup)" message)
      | Error Export.Collision -> Alcotest.fail "unexpected collision"
      | Ok () -> Alcotest.fail "persistent cleanup failure reported success");
      Alcotest.(check bool) "destination still rolled back" false (Sys.file_exists output);
      Alcotest.(check int)
        "orphan is diagnosed, not hidden" 1
        (List.length (temp_files root output)))

let suite =
  [
    Alcotest.test_case "input descriptor survives path replacement" `Quick
      test_input_descriptor_is_stable;
    Alcotest.test_case "FIFO input is nonblocking refusal" `Quick
      test_fifo_is_rejected_without_blocking;
    Alcotest.test_case "atomic success and collision cleanup" `Quick
      test_atomic_success_and_collision;
    Alcotest.test_case "parent fsync failure rolls back" `Quick test_parent_sync_failure_rolls_back;
    Alcotest.test_case "temporary cleanup retries and reports" `Quick
      test_cleanup_failure_is_retried_and_reported;
    Alcotest.test_case "persistent cleanup failure is diagnosed" `Quick
      test_persistent_cleanup_failure_is_diagnosed;
  ]
