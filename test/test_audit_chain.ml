open Jacquard

(* ET.3: the canonical Audit chain, published heads, and strict offline verification. *)

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let parse source =
  match Reader.parse_one ~file:"audit-entry.golden" source with
  | Ok form -> form
  | Error diagnostics -> fail_diags "parse AuditEntry fixture" diagnostics

let entries =
  List.map parse
    [
      "(audit-entry-v2 (evaluated-v2 (governance-v0) (lit 0) (hash \
       #aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) (hash \
       #bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) \
       (governance-assessment-v0 (governance-v0) (medium) (lit 0.75) (text-list-v1 (lit \"rule \
       matched\")) (evidence (lit \"typed\"))) (ask)))";
      "(audit-entry-v2 (consented-v2 (governance-v0) (lit 1) (hash \
       #aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) (hash \
       #cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc) (approved-v1 (hash \
       #cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc) (lit \"reviewer\") \
       (ticket (lit \"T-7\")))))";
      "(audit-entry-v2 (completed-v2 (governance-v0) (lit 2) (hash \
       #aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) (lit \"live\") \
       (governance-outcome-summary-v0 (governance-v0) (lit \"succeeded\") (hash \
       #dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd) (lit \"receipt-7\"))))";
    ]

let hash label = Form.form "hash" [ Form.Hash (Hash.of_string label) ]
let lit text = Form.form "lit" [ Form.Text text ]
let int value = Form.form "lit" [ Form.Int value ]
let governance_v0 = Form.form "governance-v0" []

let with_sequence value = function
  | {
      Form.head = "audit-entry-v2";
      args = [ Form.F ({ Form.args = version :: _old_sequence :: rest; _ } as variant) ];
      _;
    } as entry ->
      { entry with args = [ Form.F { variant with args = version :: Form.F (int value) :: rest } ] }
  | _ -> Alcotest.fail "test entry does not have a v2 sequence field"

let chain entries =
  let rec go previous records = function
    | [] -> (String.concat "" (List.rev records), previous)
    | entry :: rest -> (
        match Audit_chain.append ~previous entry with
        | Error diagnostics -> fail_diags "append Audit chain fixture" diagnostics
        | Ok record ->
            go (Audit_chain.head record) ((Audit_chain.render record ^ "\n") :: records) rest)
  in
  go Audit_chain.genesis [] entries

let golden_bytes, golden_head = chain entries

let expect_error label code = function
  | Error ({ Diag.code = actual; _ } :: _) -> Alcotest.(check string) label code actual
  | Error [] -> Alcotest.failf "%s returned an empty diagnostic list" label
  | Ok hash -> Alcotest.failf "%s accepted chain with head #%s" label (Hash.to_hex hash)

let test_fixed_golden_and_clean_verification () =
  Alcotest.(check string)
    "fixed genesis" "e30304e99930d8bf631a0b1f364b6d91f6dc798a14c7c0a554ff994ff14ab937"
    (Hash.to_hex Audit_chain.genesis);
  Alcotest.(check string)
    "fixed three-entry chain"
    (Corpus_support.read_file "../corpus/golden/audit-chain-v2.golden")
    golden_bytes;
  Alcotest.(check string)
    "fixed published head"
    (String.trim (Corpus_support.read_file "../corpus/golden/audit-chain-v2-head.golden"))
    (Hash.to_hex golden_head);
  match Audit_chain.verify_string ~file:"golden.audit" ~expected_head:golden_head golden_bytes with
  | Ok verified ->
      Alcotest.(check string) "verified head" (Hash.to_hex golden_head) (Hash.to_hex verified)
  | Error diagnostics -> fail_diags "verify fixed Audit chain" diagnostics

let records source =
  match List.rev (String.split_on_char '\n' source) with
  | "" :: reversed -> List.rev reversed
  | _ -> Alcotest.fail "test chain was not LF-terminated"

let stream lines = String.concat "\n" lines ^ "\n"

let replace_first ~pattern ~with_ source =
  Str.replace_first (Str.regexp_string pattern) with_ source

let test_structural_mutations_fail_closed () =
  match records golden_bytes with
  | [ first; second; third ] ->
      let verify source =
        Audit_chain.verify_string ~file:"mutated.audit" ~expected_head:golden_head source
      in
      expect_error "reordered" "E1303" (verify (stream [ second; first; third ]));
      expect_error "removed first" "E1303" (verify (stream [ second; third ]));
      expect_error "removed middle" "E1303" (verify (stream [ first; third ]));
      expect_error "removed tail" "E1305" (verify (stream [ first; second ]));
      expect_error "duplicated" "E1303" (verify (stream [ first; first; second; third ]));
      expect_error "wrong version" "E1302"
        (verify (replace_first ~pattern:"audit-chain-v2" ~with_:"audit-chain-v3" golden_bytes));
      expect_error "malformed" "E1301" (verify ("@" ^ golden_bytes));
      expect_error "altered entry" "E1304"
        (verify (replace_first ~pattern:"rule matched" ~with_:"rule patched" golden_bytes));
      expect_error "noncanonical whitespace" "E1301" (verify (" " ^ golden_bytes));
      expect_error "missing final LF" "E1301"
        (verify (String.sub golden_bytes 0 (String.length golden_bytes - 1)))
  | _ -> Alcotest.fail "fixed chain does not contain exactly three records"

let test_sequence_mutations_fail_closed () =
  let verify label entries =
    let bytes, head = chain entries in
    expect_error label "E1308"
      (Audit_chain.verify_string ~file:"sequence.audit" ~expected_head:head bytes)
  in
  verify "duplicate sequence" [ List.nth entries 0; with_sequence 0 (List.nth entries 1) ];
  verify "skipped sequence" [ List.nth entries 0; with_sequence 2 (List.nth entries 1) ];
  verify "decreasing sequence"
    [ List.nth entries 0; List.nth entries 1; with_sequence 1 (List.nth entries 2) ];
  verify "negative sequence" [ with_sequence (-1) (List.nth entries 0) ];
  let file = Filename.temp_file "audit-chain-negative-" ".log" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove file with Sys_error _ -> ())
    (fun () ->
      let before = Corpus_support.read_file file in
      expect_error "negative append" "E1308"
        (Audit_chain.append_file ~file ~previous:Audit_chain.genesis
           (with_sequence (-1) (List.nth entries 0)));
      Alcotest.(check string)
        "negative append wrote no bytes" before (Corpus_support.read_file file))

let test_append_sequence_mismatches_write_no_bytes () =
  let file = Filename.temp_file "audit-chain-sequence-" ".log" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove file with Sys_error _ -> ())
    (fun () ->
      let append previous entry =
        match Audit_chain.append_file ~file ~previous entry with
        | Ok head -> head
        | Error diagnostics -> fail_diags "seed append sequence mismatch file" diagnostics
      in
      let first = append Audit_chain.genesis (List.nth entries 0) in
      let second = append first (List.nth entries 1) in
      let third = append second (List.nth entries 2) in
      let reject_without_writing label sequence =
        let before = Corpus_support.read_file file in
        expect_error label "E1308"
          (Audit_chain.append_file ~file ~previous:third
             (with_sequence sequence (List.nth entries 2)));
        Alcotest.(check string) (label ^ " wrote no bytes") before (Corpus_support.read_file file)
      in
      reject_without_writing "positive duplicate append sequence" 2;
      reject_without_writing "positive skipped append sequence" 4;
      reject_without_writing "positive decreasing append sequence" 1)

let test_single_byte_mutation () =
  let bytes = Bytes.of_string golden_bytes in
  let index = Str.search_forward (Str.regexp_string "receipt-7") golden_bytes 0 in
  Bytes.set bytes index 'R';
  expect_error "one changed byte" "E1304"
    (Audit_chain.verify_string ~file:"one-byte.audit" ~expected_head:golden_head
       (Bytes.unsafe_to_string bytes))

let test_append_file_publishes_and_requires_current_head () =
  let file = Filename.temp_file "audit-chain-" ".log" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove file with Sys_error _ -> ())
    (fun () ->
      let append previous entry =
        match Audit_chain.append_file ~file ~previous entry with
        | Ok head -> head
        | Error diagnostics -> fail_diags "append Audit chain file" diagnostics
      in
      let first = append Audit_chain.genesis (List.nth entries 0) in
      let second = append first (List.nth entries 1) in
      let third = append second (List.nth entries 2) in
      Alcotest.(check string) "published head" (Hash.to_hex golden_head) (Hash.to_hex third);
      (match Audit_chain.verify_file ~file ~expected_head:third with
      | Ok _ -> ()
      | Error diagnostics -> fail_diags "verify appended Audit file" diagnostics);
      let before = Corpus_support.read_file file in
      expect_error "stale writer head" "E1305"
        (Audit_chain.append_file ~file ~previous:second (List.nth entries 0));
      Alcotest.(check string) "stale append wrote no bytes" before (Corpus_support.read_file file));
  let oversized = Filename.temp_file "audit-chain-oversized-" ".log" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove oversized with Sys_error _ -> ())
    (fun () ->
      let descriptor = Unix.openfile oversized [ Unix.O_WRONLY ] 0o600 in
      Unix.ftruncate descriptor ((16 * 1024 * 1024) + 1);
      Unix.close descriptor;
      let before = (Unix.stat oversized).st_size in
      expect_error "bounded read" "E1306"
        (Audit_chain.append_file ~file:oversized ~previous:Audit_chain.genesis (List.nth entries 0));
      Alcotest.(check int) "read failure appended no bytes" before (Unix.stat oversized).st_size)

let signal descriptor =
  let byte = Bytes.of_string "x" in
  ignore (Unix.write descriptor byte 0 1)

let await_signal descriptor =
  let byte = Bytes.create 1 in
  if Unix.read descriptor byte 0 1 <> 1 then Alcotest.fail "race helper closed unexpectedly"

let test_path_replacement_never_receives_append () =
  let file = Filename.temp_file "audit-chain-replaced-" ".log" in
  let replacement = Filename.temp_file "audit-chain-replacement-" ".log" in
  let detail = String.make (4 * 1024 * 1024) 'x' in
  let large_entry =
    Form.form "audit-entry-v2"
      [
        Form.F
          (Form.form "completed-v2"
             [
               Form.F governance_v0;
               Form.F (int 0);
               Form.F (hash "replacement-race-call");
               Form.F (lit "replacement-race");
               Form.F
                 (Form.form "governance-outcome-summary-v0"
                    [
                      Form.F governance_v0;
                      Form.F (lit "ok");
                      Form.F (hash "replacement-race-outcome");
                      Form.F (lit detail);
                    ]);
             ]);
      ]
  in
  let record =
    match Audit_chain.append ~previous:Audit_chain.genesis large_entry with
    | Ok record -> record
    | Error diagnostics -> fail_diags "build replacement-race chain" diagnostics
  in
  let channel = open_out_bin file in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel (Audit_chain.render record ^ "\n"));
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
              ignore (Unix.lseek descriptor 0 Unix.SEEK_SET);
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
      (try Sys.remove file with Sys_error _ -> ());
      try Sys.remove replacement with Sys_error _ -> ())
    (fun () ->
      await_signal ready_read;
      Unix.close ready_read;
      expect_error "pathname replaced during append" "E1306"
        (Audit_chain.append_file ~file ~previous:(Audit_chain.head record) (List.nth entries 0));
      let _, status = Unix.waitpid [] child in
      waited := true;
      Alcotest.(check bool)
        "replacement helper observed append lock" true
        (match status with Unix.WEXITED 0 -> true | _ -> false);
      Alcotest.(check int) "replacement received no record" 0 (Unix.stat file).st_size;
      Alcotest.(check int)
        "verified inode received no record" original_size (Unix.fstat observer).st_size)

let test_concurrent_truncation_is_total () =
  let file = Filename.temp_file "audit-chain-race-" ".log" in
  let race_size = 2 * 1024 * 1024 in
  let ready_read, ready_write = Unix.pipe () in
  let stop_read, stop_write = Unix.pipe () in
  let child =
    match Unix.fork () with
    | 0 ->
        Unix.close ready_read;
        Unix.close stop_write;
        let descriptor = Unix.openfile file [ Unix.O_WRONLY ] 0o600 in
        signal ready_write;
        let rec churn () =
          Unix.ftruncate descriptor 0;
          Unix.ftruncate descriptor race_size;
          match Unix.select [ stop_read ] [] [] 0. with [], [], [] -> churn () | _ -> ()
        in
        (match churn () with () -> Unix.close descriptor | exception _ -> Unix._exit 2);
        Unix._exit 0
    | child -> child
  in
  Unix.close ready_write;
  Unix.close stop_read;
  Fun.protect
    ~finally:(fun () ->
      (try signal stop_write with Unix.Unix_error _ -> ());
      Unix.close stop_write;
      ignore (Unix.waitpid [] child);
      try Sys.remove file with Sys_error _ -> ())
    (fun () ->
      await_signal ready_read;
      Unix.close ready_read;
      let classified = ref 0 in
      for _ = 1 to 64 do
        match Audit_chain.verify_file ~file ~expected_head:Audit_chain.genesis with
        | Ok _ -> incr classified
        | Error ({ Diag.code = "E1301" | "E1306"; _ } :: _) -> incr classified
        | Error ({ Diag.code; _ } :: _) ->
            Alcotest.failf "concurrent truncate returned unexpected %s" code
        | Error [] -> Alcotest.fail "concurrent read returned an empty diagnostic list"
        | exception exception_ ->
            Alcotest.failf "concurrent truncate escaped %s" (Printexc.to_string exception_)
      done;
      Alcotest.(check int) "all concurrent reads stayed result-total" 64 !classified)

let mutate source index =
  let bytes = Bytes.of_string source in
  let current = Bytes.get bytes index in
  Bytes.set bytes index (if current = 'x' then 'y' else 'x');
  Bytes.unsafe_to_string bytes

let prop_every_one_byte_mutation_is_rejected =
  QCheck.Test.make ~count:160 ~name:"every sampled one-byte chain mutation fails closed"
    QCheck.(make Gen.(int_bound (String.length golden_bytes - 1)))
    (fun index ->
      match
        Audit_chain.verify_string ~file:"byte-property.audit" ~expected_head:golden_head
          (mutate golden_bytes index)
      with
      | Error (_ :: _) -> true
      | Error [] | Ok _ -> false
      | exception _ -> false)

let evaluated_entry sequence suffix =
  Form.form "audit-entry-v2"
    [
      Form.F
        (Form.form "evaluated-v2"
           [
             Form.F governance_v0;
             Form.F (int sequence);
             Form.F (hash ("evaluated-call-" ^ suffix));
             Form.F (hash "property-policy");
             Form.F
               (Form.form "governance-assessment-v0"
                  [
                    Form.F governance_v0;
                    Form.F (Form.form "medium" []);
                    Form.F (Form.form "lit" [ Form.Real 0.5 ]);
                    Form.F (Form.form "text-list-v1" [ Form.F (lit ("reason-" ^ suffix)) ]);
                    Form.F (Form.form "evidence" [ Form.F (lit ("proof-" ^ suffix)) ]);
                  ]);
             Form.F (Form.form "ask" []);
           ]);
    ]

let consented_entry sequence suffix =
  let proposal = hash ("proposal-" ^ suffix) in
  Form.form "audit-entry-v2"
    [
      Form.F
        (Form.form "consented-v2"
           [
             Form.F governance_v0;
             Form.F (int sequence);
             Form.F (hash ("consented-call-" ^ suffix));
             Form.F proposal;
             Form.F
               (Form.form "approved-v1"
                  [
                    Form.F proposal;
                    Form.F (lit ("reviewer-" ^ suffix));
                    Form.F (Form.form "ticket" [ Form.F (lit ("T-" ^ suffix)) ]);
                  ]);
           ]);
    ]

let completed_entry sequence suffix =
  Form.form "audit-entry-v2"
    [
      Form.F
        (Form.form "completed-v2"
           [
             Form.F governance_v0;
             Form.F (int sequence);
             Form.F (hash "property-call");
             Form.F (lit ("branch-" ^ suffix));
             Form.F
               (Form.form "governance-outcome-summary-v0"
                  [
                    Form.F governance_v0;
                    Form.F (lit "ok");
                    Form.F (hash "property-outcome");
                    Form.F (lit ("detail-" ^ suffix));
                  ]);
           ]);
    ]

let prop_generated_chains_verify =
  QCheck.Test.make ~count:50 ~name:"generated canonical chains reconstruct their published head"
    QCheck.(make Gen.(list_size (1 -- 8) string_small))
    (fun suffixes ->
      let generated =
        List.mapi
          (fun index suffix ->
            let base = index * 3 in
            [
              evaluated_entry base suffix;
              consented_entry (base + 1) suffix;
              completed_entry (base + 2) suffix;
            ])
          suffixes
        |> List.concat
      in
      let bytes, expected_head = chain generated in
      match Audit_chain.verify_string ~file:"generated.audit" ~expected_head bytes with
      | Ok actual -> Hash.equal actual expected_head
      | Error _ -> false)

let suite =
  [
    Alcotest.test_case "fixed golden verifies" `Quick test_fixed_golden_and_clean_verification;
    Alcotest.test_case "structural mutations fail closed" `Quick
      test_structural_mutations_fail_closed;
    Alcotest.test_case "sequence mutations fail closed" `Quick test_sequence_mutations_fail_closed;
    Alcotest.test_case "append sequence mismatches write no bytes" `Quick
      test_append_sequence_mismatches_write_no_bytes;
    Alcotest.test_case "single-byte mutation" `Quick test_single_byte_mutation;
    Alcotest.test_case "append and concurrent reads fail closed" `Quick (fun () ->
        test_append_file_publishes_and_requires_current_head ();
        test_path_replacement_never_receives_append ();
        test_concurrent_truncation_is_total ());
    QCheck_alcotest.to_alcotest prop_every_one_byte_mutation_is_rejected;
    QCheck_alcotest.to_alcotest prop_generated_chains_verify;
  ]
