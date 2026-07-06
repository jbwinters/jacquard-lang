(* The native fuzz lane (docs/native-plan.md, task 74): generate random pure
   programs typed by construction, run both engines, and byte-compare stdout,
   stderr, and the exit status. Every case is seeded, so a divergence report
   reproduces with `native_fuzz.exe <count> <base-seed>`.

   The generator emits kernel s-expressions directly: int expressions over
   literals, bound variables, wrapping arithmetic (div/mod included — a zero
   divisor is a PARITY case, both engines must die with the same rendering),
   let/match/lambda-application/tuple-destructuring, list.length over ranges,
   and a bounded recursive countdown. Types are respected structurally, so
   every program checks; effects never appear, so every program is eligible.
   (The qcheck form generators in test_form.ml produce untyped forms and
   cannot seed this lane; the plan's "reuse" pointer ends at their shrink
   discipline, not their output.) *)

let buf = Buffer.create 512
let addf fmt = Printf.ksprintf (Buffer.add_string buf) fmt

let rec gen_int st (env : string list) (depth : int) : unit =
  let leaf () =
    if env <> [] && Random.State.int st 3 = 0 then
      addf "(var %s)" (List.nth env (Random.State.int st (List.length env)))
    else addf "(lit %d)" (Random.State.int st 101 - 50)
  in
  if depth <= 0 then leaf ()
  else
    match Random.State.int st 10 with
    | 0 | 1 | 2 ->
        let op = [| "add"; "sub"; "mul"; "div"; "mod" |].(Random.State.int st 5) in
        addf "(app (var %s) " op;
        gen_int st env (depth - 1);
        addf " ";
        gen_int st env (depth - 1);
        addf ")"
    | 3 ->
        addf "(match ";
        gen_bool st env (depth - 1);
        addf " (clause (pcon true) ";
        gen_int st env (depth - 1);
        addf ") (clause (pcon false) ";
        gen_int st env (depth - 1);
        addf "))"
    | 4 ->
        let x = Printf.sprintf "x%d" (List.length env) in
        addf "(let nonrec (pvar %s) " x;
        gen_int st env (depth - 1);
        addf " ";
        gen_int st (x :: env) (depth - 1);
        addf ")"
    | 5 ->
        let x = Printf.sprintf "x%d" (List.length env) in
        addf "(app (lam ((pvar %s)) " x;
        gen_int st (x :: env) (depth - 1);
        addf ") ";
        gen_int st env (depth - 1);
        addf ")"
    | 6 ->
        let x = Printf.sprintf "x%d" (List.length env) in
        let y = Printf.sprintf "y%d" (List.length env) in
        addf "(match (tuple ";
        gen_int st env (depth - 1);
        addf " ";
        gen_int st env (depth - 1);
        addf ") (clause (ptuple (pvar %s) (pvar %s)) (app (var add) (var %s) (var %s))))" x y x y
    | 7 ->
        addf "(app (var list.length) (app (var list.range) (lit %d) (lit %d)))"
          (Random.State.int st 5) (Random.State.int st 30)
    | 8 ->
        (* a bounded recursive countdown: self tail calls exercise loopification *)
        let f = Printf.sprintf "f%d" (List.length env) in
        let n = Printf.sprintf "n%d" (List.length env) in
        addf
          "(let rec (pvar %s) (lam ((pvar %s)) (match (app (var lt) (var %s) (lit 1)) (clause \
           (pcon true) "
          f n n;
        gen_int st env (depth - 1);
        addf
          ") (clause (pcon false) (app (var %s) (app (var sub) (var %s) (lit 1)))))) (app (var %s) \
           (lit %d)))"
          f n f (Random.State.int st 20);
        ()
    | _ -> leaf ()

and gen_bool st env depth : unit =
  if depth <= 0 then addf "(var %s)" (if Random.State.bool st then "true" else "false")
  else
    match Random.State.int st 3 with
    | 0 ->
        addf "(app (var lt) ";
        gen_int st env (depth - 1);
        addf " ";
        gen_int st env (depth - 1);
        addf ")"
    | 1 ->
        addf "(app (var eq) ";
        gen_int st env (depth - 1);
        addf " ";
        gen_int st env (depth - 1);
        addf ")"
    | _ -> addf "(var %s)" (if Random.State.bool st then "true" else "false")

let generate (seed : int) : string =
  Buffer.clear buf;
  let st = Random.State.make [| seed |] in
  gen_int st [] (2 + Random.State.int st 4);
  Buffer.contents buf ^ "\n"

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let sh cmd = Sys.command cmd

let () =
  let count = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 1000 in
  let base = if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 74 in
  let bin = try Sys.getenv "JACQUARD" with Not_found -> "jacquard" in
  (try Unix.mkdir "_fuzz" 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let failures = ref 0 in
  for i = 0 to count - 1 do
    let seed = base + i in
    let src = generate seed in
    let f = "_fuzz/case.jqd" in
    let oc = open_out f in
    output_string oc src;
    close_out oc;
    let ie = sh (Printf.sprintf "%s run %s < /dev/null > _fuzz/i.out 2> _fuzz/i.err" bin f) in
    let be = sh (Printf.sprintf "%s build %s -o _fuzz/prog > /dev/null 2> _fuzz/b.err" bin f) in
    if be <> 0 then begin
      Printf.printf "FUZZ REFUSED (seed %d):\n%s%s\n" seed src (read_file "_fuzz/b.err");
      incr failures
    end
    else begin
      let ne = sh "_fuzz/prog < /dev/null > _fuzz/n.out 2> _fuzz/n.err" in
      let same_out = read_file "_fuzz/i.out" = read_file "_fuzz/n.out" in
      let same_err = read_file "_fuzz/i.err" = read_file "_fuzz/n.err" in
      if ie <> ne || (not same_out) || not same_err then begin
        Printf.printf
          "FUZZ DIVERGED (seed %d): exit %d/%d out=%b err=%b\n\
           %s--- interpreter\n\
           %s%s--- native\n\
           %s%s"
          seed ie ne same_out same_err src (read_file "_fuzz/i.out") (read_file "_fuzz/i.err")
          (read_file "_fuzz/n.out") (read_file "_fuzz/n.err");
        incr failures
      end
    end;
    if (i + 1) mod 100 = 0 then Printf.printf "fuzz: %d/%d\n%!" (i + 1) count
  done;
  if !failures > 0 then begin
    Printf.printf "native fuzz: %d divergence(s)\n" !failures;
    exit 1
  end;
  Printf.printf "native fuzz: %d cases, no divergence\n" count
