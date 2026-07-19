open Jacquard

let form head values = Form.form head (List.map (fun value -> Form.F value) values)
let hash seed = Hash.of_string ("gm13-queue-test:" ^ seed)

(* [hash] Code has a scalar hash leaf, unlike the ordinary all-form helper above. *)
let hash_code value = Form.form "hash" [ Form.Hash value ]
let lit value = Form.form "lit" [ Form.Text value ]
let version = form "governance-v0" []
let authority = form "governance-authority-list-v0" []
let none = form "none-v0" []

let proposal seed =
  form "governance-proposal-v0"
    [
      version;
      hash_code (hash (seed ^ ":call"));
      hash_code (hash (seed ^ ":policy"));
      hash_code (hash (seed ^ ":assessment"));
      authority;
      none;
      form "review-v1" [ lit seed ];
      lit ("approve " ^ seed);
    ]

let proposal_id value =
  match Governance_approval_queue.proposal_id value with
  | Ok value -> value
  | Error diagnostics ->
      Alcotest.failf "fixture Proposal failed: %s"
        (String.concat "; " (List.map Diag.to_string diagnostics))

let approved proposal_id actor =
  form "approved-v1" [ hash_code proposal_id; lit actor; form "approval-proof-v1" [] ]

let denied proposal_id actor = form "denied-v1" [ hash_code proposal_id; lit actor; lit "no" ]
let escalated proposal_id = form "escalate-v1" [ hash_code proposal_id; lit "needs owner" ]

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let expect_error label code = function
  | Error (diagnostic :: _) ->
      Alcotest.(check string) (label ^ " code") code (Diag.code_or_uncoded diagnostic)
  | Error [] -> Alcotest.failf "%s returned no diagnostics" label
  | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label

let read_file file =
  let channel = open_in_bin file in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let write_file file bytes =
  let channel = open_out_bin file in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () -> output_string channel bytes)

let with_file use =
  let file = Filename.temp_file "governance-approval-queue-" ".journal" in
  Fun.protect ~finally:(fun () -> try Sys.remove file with Sys_error _ -> ()) (fun () -> use file)

let with_missing_file use =
  let file = Filename.temp_file "governance-approval-queue-missing-" ".journal" in
  Sys.remove file;
  Fun.protect ~finally:(fun () -> try Sys.remove file with Sys_error _ -> ()) (fun () -> use file)

let submit file proposal =
  let proposal_id = proposal_id proposal in
  match
    Governance_approval_queue.submit_file ~file ~proposal_id ~proposal
      ~allowed_approvers:[ "principal:alice"; "principal:bob" ]
  with
  | Ok result -> (proposal_id, result)
  | Error diagnostics -> fail_diags "submit" diagnostics

let decide file proposal_id actor decision =
  match Governance_approval_queue.decide_file ~file ~proposal_id ~actor ~decision with
  | Ok value -> value
  | Error diagnostics -> fail_diags "decide" diagnostics

let consume file proposal_id =
  match Governance_approval_queue.consume_file ~file ~proposal_id with
  | Ok value -> value
  | Error diagnostics -> fail_diags "consume" diagnostics

let inspect file =
  match Governance_approval_queue.inspect_file ~file with
  | Ok (Governance_approval_queue.Snapshot value) -> value
  | Ok Governance_approval_queue.Busy_inspection -> Alcotest.fail "inspection unexpectedly busy"
  | Error diagnostics -> fail_diags "inspect" diagnostics

let check_applied = function
  | Governance_approval_queue.Applied head -> head
  | Governance_approval_queue.Unchanged _ -> Alcotest.fail "expected Applied, found Unchanged"
  | Governance_approval_queue.Stale -> Alcotest.fail "expected Applied, found Stale"
  | Governance_approval_queue.Busy -> Alcotest.fail "expected Applied, found Busy"

let lines bytes =
  match List.rev (String.split_on_char '\n' bytes) with
  | "" :: reversed -> List.rev reversed
  | _ -> Alcotest.fail "journal fixture is not LF terminated"

let stream values = String.concat "\n" values ^ "\n"
let queue_approvers values = form "governance-approval-queue-approvers-v1" (List.map lit values)

let submit_event proposal_id proposal allowed_approvers =
  form "governance-approval-queue-submitted-v1"
    [ hash_code proposal_id; proposal; queue_approvers allowed_approvers ]

let decide_event proposal_id actor decision =
  form "governance-approval-queue-decided-v1" [ hash_code proposal_id; lit actor; decision ]

let consume_event proposal_id decision_id =
  form "governance-approval-queue-consumed-v1" [ hash_code proposal_id; hash_code decision_id ]

let transaction previous event =
  let subject = form "governance-approval-queue-record-v1" [ hash_code previous; event ] in
  let record_id = Hash.of_string (Printer.print_compact subject) in
  let envelope =
    form "governance-approval-queue-record-envelope-v1" [ hash_code record_id; subject ]
  in
  let commit = form "governance-approval-queue-commit-v1" [ hash_code record_id ] in
  (record_id, stream [ Printer.print_compact envelope; Printer.print_compact commit ])

let test_identity_and_two_phase_golden () =
  with_file (fun file ->
      let proposal = proposal "golden" in
      let proposal_id, result = submit file proposal in
      let submit_head = check_applied result in
      Alcotest.(check string)
        "fixed genesis" "a830520c64d4dd55483b1829c289866e74fdec839a3fc12d6fcdc6da760e10ed"
        (Hash.to_hex Governance_approval_queue.genesis);
      Alcotest.(check string)
        "Proposal identity remains exact Code HASH_V0"
        (Hash.to_hex (Hash.of_string (Printer.print_compact proposal)))
        (Hash.to_hex proposal_id);
      Alcotest.(check string)
        "fixed Submit record identity"
        "2a2550aa6127b030dba0b45605ed3b5fac30a1e829693d685b9b8a7e801f13ea" (Hash.to_hex submit_head);
      (match lines (read_file file) with
      | [ record; commit ] ->
          Alcotest.(check bool)
            "namespaced record envelope" true
            (String.starts_with ~prefix:"(governance-approval-queue-record-envelope-v1" record);
          Alcotest.(check bool)
            "separate commit line" true
            (String.starts_with ~prefix:"(governance-approval-queue-commit-v1" commit)
      | actual ->
          Alcotest.failf "Submit wrote %d lines instead of record+commit" (List.length actual));
      let snapshot = inspect file in
      Alcotest.(check int) "one committed transition" 1 snapshot.records;
      Alcotest.(check bool) "clean tail" false snapshot.recoverable_tail;
      Alcotest.(check string)
        "head is Submit record" (Hash.to_hex submit_head) (Hash.to_hex snapshot.head))

let test_decide_and_consume_record_identities () =
  with_file (fun file ->
      let proposal = proposal "golden" in
      let proposal_id, submitted = submit file proposal in
      let submit_head = check_applied submitted in
      let decision = approved proposal_id "principal:alice" in
      let decide_head = check_applied (decide file proposal_id "principal:alice" decision) in
      Alcotest.(check string)
        "fixed Decide record identity"
        "8b9b2196ad07264e45bb5abd11be5f9cd20a5a8853fc25c9a835079872b54d36" (Hash.to_hex decide_head);
      (match consume file proposal_id with
      | Governance_approval_queue.Delivered { decision_id; head; _ } ->
          Alcotest.(check string)
            "fixed Decision identity"
            "683c831bb4d597563d553b21488a906522a599cbf5ff2a45afebb22113b06f40"
            (Hash.to_hex decision_id);
          Alcotest.(check string)
            "fixed Consume record identity"
            "2537e339b618dd166867ace0deb3dd370aea3f8b26bd0ca53d0582f6ee57b808" (Hash.to_hex head)
      | _ -> Alcotest.fail "golden Decision was not delivered");
      Alcotest.(check int)
        "Submit, Decide, and Consume committed" 6
        (List.length (lines (read_file file)));
      Alcotest.(check string)
        "Submit remains first predecessor"
        "2a2550aa6127b030dba0b45605ed3b5fac30a1e829693d685b9b8a7e801f13ea" (Hash.to_hex submit_head))

let test_missing_path_creation_is_private_and_restartable () =
  with_missing_file (fun file ->
      let proposal = proposal "missing-path" in
      let id, submitted = submit file proposal in
      ignore (check_applied submitted);
      let stats = Unix.lstat file in
      Alcotest.(check bool) "created a regular journal" true (stats.st_kind = Unix.S_REG);
      Alcotest.(check int) "created journal mode" 0o600 (stats.st_perm land 0o777);
      Alcotest.(check int) "restart sees committed Submit" 1 (inspect file).records;
      match snd (submit file proposal) with
      | Governance_approval_queue.Unchanged head ->
          Alcotest.(check string)
            "restart retry preserves head" (Hash.to_hex (inspect file).head) (Hash.to_hex head);
          Alcotest.(check string)
            "Proposal identity survives creation" (Hash.to_hex id)
            (Hash.to_hex (proposal_id proposal))
      | _ -> Alcotest.fail "missing-path Submit retry was not idempotent")

let test_all_decisions_deliver_once_and_stay_stale () =
  List.iter
    (fun (label, make_decision) ->
      with_file (fun file ->
          let proposal = proposal label in
          let proposal_id, submitted = submit file proposal in
          ignore (check_applied submitted);
          let decision = make_decision proposal_id in
          ignore (check_applied (decide file proposal_id "principal:alice" decision));
          (match consume file proposal_id with
          | Governance_approval_queue.Delivered delivered ->
              Alcotest.(check bool)
                (label ^ " exact Decision") true
                (Form.equal_ignoring_meta decision delivered.decision);
              Alcotest.(check string) (label ^ " actor") "principal:alice" delivered.actor;
              let expected = Hash.of_string (Printer.print_compact decision) in
              Alcotest.(check string)
                (label ^ " Decision identity") (Hash.to_hex expected)
                (Hash.to_hex delivered.decision_id)
          | _ -> Alcotest.failf "%s was not delivered" label);
          (match consume file proposal_id with
          | Governance_approval_queue.Stale_delivery -> ()
          | _ -> Alcotest.failf "%s was delivered more than once" label);
          (match inspect file with
          | {
           records = 3;
           items = [ { status = Governance_approval_queue.Stale_decision evidence; _ } ];
           _;
          } ->
              Alcotest.(check bool)
                (label ^ " stale evidence retained")
                true
                (Form.equal_ignoring_meta decision evidence.decision)
          | _ -> Alcotest.failf "%s did not persist exact stale state" label);
          (match decide file proposal_id "principal:alice" decision with
          | Governance_approval_queue.Stale -> ()
          | _ -> Alcotest.failf "%s stale Decide was not refused" label);
          match snd (submit file proposal) with
          | Governance_approval_queue.Stale -> ()
          | _ -> Alcotest.failf "%s stale Submit reset durable state" label))
    [
      ("approved", fun id -> approved id "principal:alice");
      ("denied", fun id -> denied id "principal:alice");
      ("escalated", escalated);
    ]

let test_idempotency_drift_and_authentication () =
  with_file (fun file ->
      let proposal = proposal "idempotency" in
      let id, submitted = submit file proposal in
      ignore (check_applied submitted);
      (match snd (submit file proposal) with
      | Governance_approval_queue.Unchanged _ -> ()
      | _ -> Alcotest.fail "exact Submit retry was not idempotent");
      expect_error "Submit config drift" "E1525"
        (Governance_approval_queue.submit_file ~file ~proposal_id:id ~proposal
           ~allowed_approvers:[ "principal:alice" ]);
      (match consume file id with
      | Governance_approval_queue.Pending_delivery -> ()
      | _ -> Alcotest.fail "Pending Consume mutated state");
      let exact = approved id "principal:alice" in
      expect_error "unauthorized actor" "E1524"
        (Governance_approval_queue.decide_file ~file ~proposal_id:id ~actor:"principal:eve"
           ~decision:(approved id "principal:eve"));
      expect_error "actor/Decision mismatch" "E1524"
        (Governance_approval_queue.decide_file ~file ~proposal_id:id ~actor:"principal:alice"
           ~decision:(approved id "principal:bob"));
      ignore (check_applied (decide file id "principal:alice" exact));
      (match decide file id "principal:alice" exact with
      | Governance_approval_queue.Unchanged _ -> ()
      | _ -> Alcotest.fail "exact Decide retry was not idempotent");
      expect_error "different Decision conflict" "E1525"
        (Governance_approval_queue.decide_file ~file ~proposal_id:id ~actor:"principal:alice"
           ~decision:(denied id "principal:alice"));
      Alcotest.(check int) "only Submit+Decide committed" 2 (inspect file).records)

let test_strict_verification_and_tail_recovery () =
  with_file (fun file ->
      let proposal = proposal "recovery" in
      let id, submitted = submit file proposal in
      ignore (check_applied submitted);
      let pending = read_file file in
      ignore (check_applied (decide file id "principal:alice" (approved id "principal:alice")));
      let decided_lines = lines (read_file file) in
      let decision_record = List.nth decided_lines 2 in
      let decision_commit = List.nth decided_lines 3 in
      let cases =
        [
          ("partial record", pending ^ String.sub decision_record 0 19);
          ("complete record", pending ^ decision_record ^ "\n");
          ("partial commit", pending ^ decision_record ^ "\n" ^ String.sub decision_commit 0 23);
        ]
      in
      List.iter
        (fun (label, bytes) ->
          write_file file bytes;
          expect_error (label ^ " strict") "E1520"
            (Governance_approval_queue.verify_string ~file:"tail.queue" bytes);
          Alcotest.(check bool) (label ^ " reported") true (inspect file).recoverable_tail;
          (match Governance_approval_queue.recover_file ~file with
          | Ok (Governance_approval_queue.Applied head) ->
              Alcotest.(check string)
                (label ^ " recovers to pending head")
                (Hash.to_hex (inspect file).head) (Hash.to_hex head)
          | Ok _ -> Alcotest.failf "%s was not recovered" label
          | Error diagnostics -> fail_diags (label ^ " recovery") diagnostics);
          Alcotest.(check string) (label ^ " truncates exactly") pending (read_file file);
          Alcotest.(check bool) (label ^ " tail clean") false (inspect file).recoverable_tail)
        cases;
      write_file file (pending ^ "corrupt-tail");
      expect_error "arbitrary non-LF tail" "E1520" (Governance_approval_queue.inspect_file ~file);
      let noncanonical =
        Str.replace_first
          (Str.regexp_string "(governance-approval-queue-record-envelope-v1 ")
          "(governance-approval-queue-record-envelope-v1  " pending
      in
      write_file file noncanonical;
      expect_error "complete noncanonical record line" "E1520"
        (Governance_approval_queue.inspect_file ~file);
      write_file file (pending ^ "(governance-approval-queue-bogus-v1)\n");
      expect_error "LF-terminated malformed record" "E1521"
        (Governance_approval_queue.inspect_file ~file);
      write_file file
        (pending ^ decision_record ^ "\n" ^ "(governance-approval-queue-commit-v1 (hash #"
       ^ String.make 64 '0' ^ "))\n");
      expect_error "wrong full commit" "E1522" (Governance_approval_queue.inspect_file ~file))

let test_committed_corruption_fails_closed () =
  with_file (fun file ->
      let proposal = proposal "corruption" in
      let id, submitted = submit file proposal in
      ignore (check_applied submitted);
      ignore (check_applied (decide file id "principal:alice" (approved id "principal:alice")));
      let bytes = read_file file in
      let corrupted =
        Str.replace_first (Str.regexp_string "principal:alice") "principal:alixe" bytes
      in
      write_file file corrupted;
      expect_error "committed record mutation" "E1522"
        (Governance_approval_queue.inspect_file ~file);
      expect_error "mutation cannot auto-recover corruption" "E1522"
        (Governance_approval_queue.consume_file ~file ~proposal_id:id))

let test_committed_illegal_and_versioned_events_fail_closed () =
  with_file (fun file ->
      let proposal = proposal "illegal-transition" in
      let id, submitted = submit file proposal in
      let submit_head = check_applied submitted in
      let committed = read_file file in
      let _, illegal_consume = transaction submit_head (consume_event id (hash "not-decided")) in
      let consume_bytes = committed ^ illegal_consume in
      expect_error "committed Consume of pending Proposal" "E1525"
        (Governance_approval_queue.verify_string ~file:"illegal-consume.queue" consume_bytes);
      write_file file consume_bytes;
      expect_error "file verifier rejects committed illegal Consume" "E1525"
        (Governance_approval_queue.inspect_file ~file);
      let _, duplicate_submit =
        transaction submit_head (submit_event id proposal [ "principal:alice"; "principal:bob" ])
      in
      expect_error "committed duplicate Submit" "E1525"
        (Governance_approval_queue.verify_string ~file:"duplicate-submit.queue"
           (committed ^ duplicate_submit));
      let _, malformed_v1 =
        transaction submit_head (form "governance-approval-queue-decided-v1" [])
      in
      expect_error "recognized malformed v1 event" "E1520"
        (Governance_approval_queue.verify_string ~file:"malformed-v1.queue"
           (committed ^ malformed_v1));
      let _, future_event =
        transaction submit_head (form "governance-approval-queue-decided-v2" [])
      in
      expect_error "unsupported event version" "E1521"
        (Governance_approval_queue.verify_string ~file:"future-event.queue"
           (committed ^ future_event)))

let child_exit_for_delivery file proposal_id =
  let rec retry attempts =
    match Governance_approval_queue.consume_file ~file ~proposal_id with
    | Ok (Governance_approval_queue.Delivered _) -> Unix._exit 10
    | Ok Governance_approval_queue.Stale_delivery -> Unix._exit 20
    | Ok Governance_approval_queue.Busy_delivery when attempts > 0 ->
        Unix.sleepf 0.0001;
        retry (attempts - 1)
    | Ok Governance_approval_queue.Busy_delivery -> Unix._exit 30
    | Ok Governance_approval_queue.Pending_delivery | Error _ -> Unix._exit 99
  in
  retry 10_000

let test_concurrent_consumers_exactly_one_delivery () =
  with_file (fun file ->
      let proposal = proposal "race" in
      let id, submitted = submit file proposal in
      ignore (check_applied submitted);
      ignore (check_applied (decide file id "principal:alice" (approved id "principal:alice")));
      let children =
        List.init 2 (fun _ ->
            match Unix.fork () with 0 -> child_exit_for_delivery file id | pid -> pid)
      in
      let exits =
        List.map
          (fun child ->
            match snd (Unix.waitpid [] child) with
            | Unix.WEXITED code -> code
            | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
                Alcotest.failf "consumer child stopped by signal %d" signal)
          children
        |> List.sort Int.compare
      in
      Alcotest.(check (list int)) "one delivery and one stale observation" [ 10; 20 ] exits;
      Alcotest.(check int) "one durable Consume" 3 (inspect file).records)

let consume_with_retry file proposal_id =
  let rec retry attempts =
    match Governance_approval_queue.consume_file ~file ~proposal_id with
    | Ok (Governance_approval_queue.Delivered _) -> `Delivered
    | Ok Governance_approval_queue.Stale_delivery -> `Stale
    | Ok Governance_approval_queue.Busy_delivery when attempts > 0 ->
        Domain.cpu_relax ();
        retry (attempts - 1)
    | Ok Governance_approval_queue.Busy_delivery -> `Busy
    | Ok Governance_approval_queue.Pending_delivery | Error _ -> `Other
  in
  retry 1_000_000

let test_domain_consumers_exactly_one_delivery () =
  with_file (fun file ->
      let proposal = proposal "domain-race" in
      let id, submitted = submit file proposal in
      ignore (check_applied submitted);
      ignore (check_applied (decide file id "principal:alice" (approved id "principal:alice")));
      let start = Atomic.make false in
      let consumer =
        Domain.spawn (fun () ->
            while not (Atomic.get start) do
              Domain.cpu_relax ()
            done;
            consume_with_retry file id)
      in
      Atomic.set start true;
      let local = consume_with_retry file id in
      let remote = Domain.join consumer in
      Alcotest.(check (list string))
        "Domain guard yields one delivery and one stale result" [ "delivered"; "stale" ]
        (List.sort String.compare
           (List.map
              (function
                | `Delivered -> "delivered"
                | `Stale -> "stale"
                | `Busy -> "busy"
                | `Other -> "other")
              [ local; remote ]));
      Alcotest.(check int) "Domains append one durable Consume" 3 (inspect file).records)

let test_nonblocking_lock_and_unsafe_inputs () =
  with_file (fun file ->
      let proposal = proposal "busy" in
      let _id, submitted = submit file proposal in
      ignore (check_applied submitted);
      let descriptor = Unix.openfile file [ Unix.O_RDWR ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          Unix.lockf descriptor Unix.F_TLOCK 0;
          let child =
            match Unix.fork () with
            | 0 -> (
                match Governance_approval_queue.inspect_file ~file with
                | Ok Governance_approval_queue.Busy_inspection -> Unix._exit 42
                | _ -> Unix._exit 99)
            | child -> child
          in
          match snd (Unix.waitpid [] child) with
          | Unix.WEXITED 42 -> ()
          | _ -> Alcotest.fail "lock contention did not return Busy"));
  let fifo = Filename.temp_file "approval-queue-fifo-" ".journal" in
  Sys.remove fifo;
  Unix.mkfifo fifo 0o600;
  Fun.protect
    ~finally:(fun () -> try Sys.remove fifo with Sys_error _ -> ())
    (fun () ->
      expect_error "FIFO refusal is nonblocking" "E1526"
        (Governance_approval_queue.inspect_file ~file:fifo));
  with_file (fun file ->
      let descriptor = Unix.openfile file [ Unix.O_WRONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () -> Unix.ftruncate descriptor ((16 * 1024 * 1024) + 1));
      expect_error "bounded journal" "E1526" (Governance_approval_queue.inspect_file ~file));
  with_file (fun target ->
      let link = target ^ ".link" in
      Unix.symlink target link;
      Fun.protect
        ~finally:(fun () -> try Sys.remove link with Sys_error _ -> ())
        (fun () ->
          expect_error "symlink refusal" "E1526" (Governance_approval_queue.inspect_file ~file:link)))

let signal descriptor = ignore (Unix.write descriptor (Bytes.of_string "x") 0 1)

let await_signal descriptor =
  let byte = Bytes.create 1 in
  ignore (Unix.read descriptor byte 0 1)

let test_path_replacement_is_not_acknowledged () =
  with_file (fun file ->
      let proposal = proposal "replacement" in
      let id, submitted = submit file proposal in
      ignore (check_applied submitted);
      let replacement = Filename.temp_file "approval-queue-replacement-" ".journal" in
      let observer = Unix.openfile file [ Unix.O_RDONLY ] 0 in
      let original_size = (Unix.fstat observer).st_size in
      let ready_read, ready_write = Unix.pipe () in
      let child =
        match Unix.fork () with
        | 0 ->
            Unix.close ready_read;
            let descriptor = Unix.openfile file [ Unix.O_RDWR ] 0 in
            signal ready_write;
            Unix.close ready_write;
            let rec replace_when_locked attempts =
              if attempts = 0 then Unix._exit 2
              else
                try
                  Unix.lockf descriptor Unix.F_TEST 0;
                  Unix.sleepf 0.00005;
                  replace_when_locked (attempts - 1)
                with
                | Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
                    Unix.rename replacement file;
                    Unix.close descriptor;
                    Unix._exit 0
                | _ -> Unix._exit 3
            in
            replace_when_locked 200_000
        | child -> child
      in
      Unix.close ready_write;
      let waited = ref false in
      Fun.protect
        ~finally:(fun () ->
          Unix.close observer;
          (try Unix.close ready_read with Unix.Unix_error _ -> ());
          if not !waited then (
            (try Unix.kill child Sys.sigterm with Unix.Unix_error _ -> ());
            ignore (Unix.waitpid [] child));
          try Sys.remove replacement with Sys_error _ -> ())
        (fun () ->
          await_signal ready_read;
          Unix.close ready_read;
          let large_decision =
            form "approved-v1"
              [
                hash_code id;
                lit "principal:alice";
                form "approval-proof-v1" [ lit (String.make (512 * 1024) 'x') ];
              ]
          in
          expect_error "pathname replacement" "E1526"
            (Governance_approval_queue.decide_file ~file ~proposal_id:id ~actor:"principal:alice"
               ~decision:large_decision);
          let _, status = Unix.waitpid [] child in
          waited := true;
          Alcotest.(check bool)
            "replacement helper observed whole-file lock" true
            (match status with Unix.WEXITED 0 -> true | _ -> false);
          Alcotest.(check int) "replacement path received no transaction" 0 (Unix.stat file).st_size;
          Alcotest.(check bool)
            "unlinked verified inode was not acknowledged" true
            ((Unix.fstat observer).st_size >= original_size)))

let test_noncanonical_and_forged_inputs () =
  let proposal = proposal "invalid" in
  let id = proposal_id proposal in
  expect_error "forged Proposal identity" "E1523"
    (Governance_approval_queue.submit_file ~file:"not-opened" ~proposal_id:(hash "forged") ~proposal
       ~allowed_approvers:[ "principal:alice" ]);
  expect_error "unsorted approvers" "E1523"
    (Governance_approval_queue.submit_file ~file:"not-opened" ~proposal_id:id ~proposal
       ~allowed_approvers:[ "principal:bob"; "principal:alice" ]);
  expect_error "duplicate approvers" "E1523"
    (Governance_approval_queue.submit_file ~file:"not-opened" ~proposal_id:id ~proposal
       ~allowed_approvers:[ "principal:alice"; "principal:alice" ]);
  expect_error "stale Decision identity" "E1524"
    (Governance_approval_queue.decision_id ~proposal_id:id
       (approved (hash "other") "principal:alice"));
  let empty_status_preview =
    form "some-v0"
      [
        form "governance-outcome-summary-v0"
          [ version; lit ""; hash_code (hash "preview"); lit "detail" ];
      ]
  in
  let invalid_preview =
    match proposal with
    | {
     Form.args = version :: call :: policy :: assessment :: authority :: _ :: rendering :: summary;
     _;
    } ->
        {
          proposal with
          args =
            version :: call :: policy :: assessment :: authority :: Form.F empty_status_preview
            :: rendering :: summary;
        }
    | _ -> Alcotest.fail "proposal fixture shape changed"
  in
  expect_error "empty preview status" "E1523"
    (Governance_approval_queue.proposal_id invalid_preview);
  let changed =
    { proposal with Form.meta = Meta.add Meta.key_origin (Meta.Text "elsewhere") Meta.empty }
  in
  Alcotest.(check string)
    "metadata does not alter Proposal identity" (Hash.to_hex id)
    (Hash.to_hex (proposal_id changed))

let suite =
  [
    Alcotest.test_case "fixed identity and two-phase framing" `Quick
      test_identity_and_two_phase_golden;
    Alcotest.test_case "fixed Decide and Consume record identities" `Quick
      test_decide_and_consume_record_identities;
    Alcotest.test_case "missing path creation is private and restartable" `Quick
      test_missing_path_creation_is_private_and_restartable;
    Alcotest.test_case "all Decisions deliver once and stay stale" `Quick
      test_all_decisions_deliver_once_and_stay_stale;
    Alcotest.test_case "idempotency, drift, and authenticated actor" `Quick
      test_idempotency_drift_and_authentication;
    Alcotest.test_case "strict verification and narrow tail recovery" `Quick
      test_strict_verification_and_tail_recovery;
    Alcotest.test_case "committed corruption fails closed" `Quick
      test_committed_corruption_fails_closed;
    Alcotest.test_case "committed illegal and versioned events fail closed" `Quick
      test_committed_illegal_and_versioned_events_fail_closed;
    Alcotest.test_case "concurrent consumers deliver exactly once" `Quick
      test_concurrent_consumers_exactly_one_delivery;
    Alcotest.test_case "nonblocking lock and bounded unsafe inputs" `Quick
      test_nonblocking_lock_and_unsafe_inputs;
    Alcotest.test_case "path replacement is not acknowledged" `Quick
      test_path_replacement_is_not_acknowledged;
    Alcotest.test_case "noncanonical and forged input refusal" `Quick
      test_noncanonical_and_forged_inputs;
    (* OCaml forbids [fork] after the process has created a Domain, even once
       that Domain has joined. Keep this test after every fork-based case. *)
    Alcotest.test_case "Domain consumers deliver exactly once" `Quick
      test_domain_consumers_exactly_one_delivery;
  ]
