(* Regenerates the native parity goldens (docs/native-plan.md, task 66) from
   the interpreter's own renderer, UTF-8 decoder, and RNG. The C side
   (runtime/test/test_parity.c) mirrors the SAME corpus in the SAME order —
   keep the two lists in lockstep — and check.sh diffs its output against
   these files. Run from the repo root:
     dune exec test/gen_native_parity.exe *)

open Jacquard

let out_dir = "corpus/golden/native"

let write name lines =
  let oc = open_out_bin (Filename.concat out_dir name) in
  List.iter (fun l -> output_string oc (l ^ "\n")) lines;
  close_out oc;
  Printf.printf "wrote %d lines to %s/%s\n" (List.length lines) out_dir name

(* --- show.golden: the Value.show corpus (lockstep with test_parity.c) --- *)

let show_corpus () =
  let expr src =
    match Reader.parse_one ~file:"gen.jqd" src with
    | Ok f -> (
        match Kernel.expr_of_form f with Ok e -> e | Error _ -> failwith "gen corpus expr")
    | Error _ -> failwith "gen corpus parse"
  in
  let con name args = Value.VCon { con = Hash.of_string name; name; args } in
  let v_closure =
    Value.VClosure { scope = Value.empty_scope; params = []; body = expr "(lit 1)" }
  in
  [
    (* ints *)
    Value.VInt 0;
    VInt 1;
    VInt (-1);
    VInt 42;
    VInt max_int;
    VInt min_int;
    (* reals: the %.15g path, the ".0" append, the 16/17-digit paths,
       signed zero, extremes, non-finite *)
    VReal 0.0;
    VReal (-0.0);
    VReal 1.0;
    VReal 1.5;
    VReal (-2.75);
    VReal 0.1;
    VReal Float.pi;
    VReal (0.1 +. 0.2);
    VReal 123456789.123456789;
    VReal 1e300;
    VReal 1e-300;
    VReal max_float;
    VReal 5e-324;
    VReal infinity;
    VReal neg_infinity;
    VReal nan;
    (* texts: escapes, controls, DEL, raw UTF-8 bytes, empty *)
    VText "";
    VText "hello";
    VText "with \"quotes\" and \\ backslash";
    VText "line\nbreak\ttab\rcr";
    VText "ctrl \x01 and del \x7f";
    VText "utf-8: h\xc3\xa9llo \xe2\x86\x92 \xf0\x9f\x8e\x89";
    (* tuples *)
    VTuple [];
    VTuple [ VInt 1 ];
    VTuple [ VInt 1; VText "two"; VReal 3.0 ];
    VTuple [ VTuple [ VInt 1; VInt 2 ]; VTuple [ VInt 3; VTuple [ VInt 4; VInt 5 ] ] ];
    (* constructors applied and not *)
    con "nil" [];
    con "cons" [ VInt 1; con "nil" [] ];
    con "some" [ VText "x" ];
    VConstructor { con = Hash.of_string "pair"; name = "pair"; arity = 2 };
    (* the placeholder renderings *)
    VOp { op = Hash.of_string "print"; name = "print"; effect_ = "console" };
    v_closure;
    VBuiltin ("add", fun _ -> Ok (Value.VTuple []));
    VResume [];
  ]

(* --- rng.golden: SplitMix64 streams (lockstep with jq_rng.c) --- *)

let rng_lines () =
  let lines = ref [] in
  let add l = lines := l :: !lines in
  List.iter
    (fun seed ->
      add (Printf.sprintf "seed %d" seed);
      let r = Infer_dist.Rng.make seed in
      for _ = 1 to 1000 do
        add (Int64.to_string (Infer_dist.Rng.next_int64 r))
      done;
      add (Printf.sprintf "floats %d" seed);
      let r = Infer_dist.Rng.make seed in
      for _ = 1 to 100 do
        add (Printer.real_repr (Infer_dist.Rng.float r))
      done)
    [ 0; 1; 42; 0x3FFFFFFF ];
  add "split-chain 42";
  let r = Infer_dist.Rng.make 42 in
  for _ = 1 to 10 do
    let child = Infer_dist.Rng.split r in
    add (Int64.to_string (Infer_dist.Rng.next_int64 child))
  done;
  List.rev !lines

(* --- utf8.golden: "<hex> <codepoint count>" (lockstep with jq_utf8.c) --- *)

let utf8_corpus =
  [
    "";
    "abc";
    "h\xc3\xa9llo";
    "\xf0\x9f\x8e\x89" (* one 4-byte codepoint *);
    "\xe2\x86\x92" (* one 3-byte codepoint *);
    "\x80" (* lone continuation: malformed, 1 per byte *);
    "\xc3" (* truncated 2-byte *);
    "\xc0\xaf" (* overlong 2-byte lead C0: malformed *);
    "\xe0\x80\x80" (* overlong 3-byte *);
    "\xed\xa0\x80" (* surrogate *);
    "\xf4\x90\x80\x80" (* beyond U+10FFFF *);
    "\xf0\x90\x8d\x88" (* valid 4-byte, boundary F0 90 *);
    "\xe0\xa0\x80" (* valid 3-byte, boundary E0 A0 *);
    "a\x80b\xc2\xa2c" (* mixed valid/malformed *);
    "\xff\xfe" (* invalid leads *);
  ]

let to_hex s =
  String.concat ""
    (List.map
       (fun c -> Printf.sprintf "%02x" (Char.code c))
       (List.init (String.length s) (String.get s)))

let () =
  (try Unix.mkdir out_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  write "show.golden" (List.map Value.show (show_corpus ()));
  write "rng.golden" (rng_lines ());
  write "utf8.golden"
    (List.map
       (fun s -> Printf.sprintf "%s %d" (to_hex s) (List.length (Prelude.utf8_boundaries s) - 1))
       utf8_corpus)
