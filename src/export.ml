(** Filesystem boundary for explicit bootstrap exports. *)

type read_error = Stdin | Not_regular | Read_failure of string
type write_error = Collision | Atomic_failure of string

type fault_point =
  | Parent_sync_after_link
  | Temp_cleanup
  | Parent_sync_after_cleanup
  | Destination_rollback
  | Temp_rollback
  | Parent_sync_after_rollback

let no_fault _ = ()

let error_message path = function
  | Unix.Unix_error (error, operation, target) ->
      Printf.sprintf "%s: %s (%s, %s)" path (Unix.error_message error) operation target
  | Sys_error message -> Printf.sprintf "%s: %s" path message
  | exn -> Printf.sprintf "%s: %s" path (Printexc.to_string exn)

let close_result ~path fd =
  try
    Unix.close fd;
    Ok ()
  with exn -> Error (error_message path exn)

let read_all fd =
  let chunk = Bytes.create 65536 in
  let buffer = Buffer.create 65536 in
  let rec loop () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents buffer
    | count ->
        Buffer.add_subbytes buffer chunk 0 count;
        loop ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()

let read_regular_file_with ~after_open path =
  if String.equal path "-" then Error Stdin
  else
    try
      let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
      let finish result =
        match (result, close_result ~path fd) with
        | Ok contents, Ok () -> Ok contents
        | Error error, Ok () -> Error error
        | _, Error message -> Error (Read_failure message)
      in
      try
        after_open ();
        match (Unix.fstat fd).Unix.st_kind with
        | Unix.S_REG ->
            Unix.clear_nonblock fd;
            finish (Ok (read_all fd))
        | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
            finish (Error Not_regular)
      with exn -> finish (Error (Read_failure (error_message path exn)))
    with exn -> Error (Read_failure (error_message path exn))

(** [read_regular_file path] opens [path] once without blocking, verifies the opened descriptor is
    regular, and reads that same descriptor. It rejects stdin and non-regular inputs and converts
    every open, stat, read, and close failure to [read_error]. *)
let read_regular_file path = read_regular_file_with ~after_open:(fun () -> ()) path

let temp_file path =
  let dir = Filename.dirname path in
  let base = Filename.basename path in
  let rec attempt n =
    let candidate = Filename.concat dir (Printf.sprintf ".%s.tmp-%d-%d" base (Unix.getpid ()) n) in
    try
      let fd = Unix.openfile candidate [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o666 in
      Ok (candidate, fd)
    with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (n + 1)
    | exn -> Error (error_message path exn)
  in
  attempt 0

let write_all fd contents =
  let bytes = Bytes.of_string contents in
  let rec loop offset =
    if offset < Bytes.length bytes then
      match Unix.write fd bytes offset (Bytes.length bytes - offset) with
      | 0 -> raise (Sys_error "zero-length write")
      | count -> loop (offset + count)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset
  in
  loop 0

let sync_parent ~fault point path =
  let dir = Filename.dirname path in
  try
    fault point;
    let fd = Unix.openfile dir [ Unix.O_RDONLY ] 0 in
    let sync_result =
      try
        Unix.fsync fd;
        Ok ()
      with exn -> Error (error_message dir exn)
    in
    match (sync_result, close_result ~path:dir fd) with
    | Ok (), Ok () -> Ok ()
    | Error message, _ | _, Error message -> Error message
  with exn -> Error (error_message dir exn)

let remove ~fault point path =
  try
    fault point;
    Unix.unlink path;
    Ok ()
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exn -> Error (error_message path exn)

let combine_errors context errors =
  match List.filter_map (function Ok () -> None | Error message -> Some message) errors with
  | [] -> context
  | messages -> context ^ "; cleanup failed: " ^ String.concat "; " messages

let rollback ~fault ~path ~temp ~remove_destination context =
  let destination = if remove_destination then remove ~fault Destination_rollback path else Ok () in
  let temporary = remove ~fault Temp_rollback temp in
  let parent = sync_parent ~fault Parent_sync_after_rollback path in
  Error (Atomic_failure (combine_errors context [ destination; temporary; parent ]))

let finish_unpublished ~fault ~path ~temp result =
  let temporary = remove ~fault Temp_cleanup temp in
  let retry = match temporary with Ok () -> Ok () | Error _ -> remove ~fault Temp_rollback temp in
  let parent = sync_parent ~fault Parent_sync_after_cleanup path in
  match (temporary, retry, parent) with
  | Ok (), Ok (), Ok () -> result
  | _ ->
      let context =
        match result with
        | Error Collision -> "destination collision"
        | Error (Atomic_failure message) -> message
        | Ok () -> "unpublished export"
      in
      Error (Atomic_failure (combine_errors context [ temporary; retry; parent ]))

let write_atomic_exclusive_with ~fault ~path contents =
  match temp_file path with
  | Error message -> Error (Atomic_failure message)
  | Ok (temp, fd) -> (
      let written =
        try
          write_all fd contents;
          Unix.fsync fd;
          close_result ~path:temp fd
        with exn -> (
          let failure = error_message path exn in
          match close_result ~path:temp fd with
          | Ok () -> Error failure
          | Error close -> Error (failure ^ "; close failed: " ^ close))
      in
      match written with
      | Error message -> finish_unpublished ~fault ~path ~temp (Error (Atomic_failure message))
      | Ok () -> (
          try
            Unix.link temp path;
            match sync_parent ~fault Parent_sync_after_link path with
            | Error message -> rollback ~fault ~path ~temp ~remove_destination:true message
            | Ok () -> (
                match remove ~fault Temp_cleanup temp with
                | Error message ->
                    rollback ~fault ~path ~temp ~remove_destination:true
                      ("temporary cleanup failed: " ^ message)
                | Ok () -> (
                    match sync_parent ~fault Parent_sync_after_cleanup path with
                    | Ok () -> Ok ()
                    | Error message -> rollback ~fault ~path ~temp ~remove_destination:true message)
                )
          with
          | Unix.Unix_error (Unix.EEXIST, _, _) ->
              finish_unpublished ~fault ~path ~temp (Error Collision)
          | exn ->
              finish_unpublished ~fault ~path ~temp
                (Error (Atomic_failure (error_message path exn)))))

(** [write_atomic_exclusive ~path contents] writes and syncs a same-directory temporary file,
    publishes it with an exclusive hard link, syncs the parent directory, removes the temporary, and
    syncs the parent again. It never replaces [path]. Failures trigger rollback; any failed rollback
    or temporary cleanup is included in [Atomic_failure] rather than silently ignored. *)
let write_atomic_exclusive ~path contents =
  write_atomic_exclusive_with ~fault:no_fault ~path contents

module For_test = struct
  type nonrec fault_point = fault_point =
    | Parent_sync_after_link
    | Temp_cleanup
    | Parent_sync_after_cleanup
    | Destination_rollback
    | Temp_rollback
    | Parent_sync_after_rollback

  let read_regular_file ~after_open path = read_regular_file_with ~after_open path

  let write_atomic_exclusive ~fault ~path contents =
    write_atomic_exclusive_with ~fault ~path contents
end
