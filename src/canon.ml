(** Canonicalization and hashing (plan W1.5, spec §6).

    The pipeline, applied to resolved kernel trees:

    1. Meta is erased (never serialized). 2. Locals become de Bruijn indices: binders push their
    variables left-to-right, an occurrence serializes as its distance to the binder (0 = most
    recently bound). Binder names are not serialized, so alpha-renaming cannot change a hash. Type
    and row variables bound by [tforall] are indexed the same way; free ones serialize by name. 3. A
    [DefTerm] group is hashed as a unit: members are put in a canonical, source-order- independent
    order (see below), in-group references serialize as [GroupRef] with the canonical index, the
    group hash is [HASH_V0] over the ordered serialization, and each member's hash is derived from
    (group hash, canonical index). Binding names are erased — term renames never touch identity. 4.
    Constructor and operation references are single hashes derived from (decl hash, ordinal):
    {!con_hash} and {!op_hash}. 5. Serialization is deterministic bytes: tag bytes per constructor,
    LEB128 lengths and indices, big-endian 64-bit scalars. The format is documented in
    [spec/serialization.md] and pinned by golden corpus hashes.

    Canonical group order: each member is serialized with in-group reference indices erased, giving
    an order-independent signature; ties are refined by re-serializing with the previous round's
    rank classes substituted for indices (at most n rounds). Refinement propagates only
    out-references, so members can stay tied even when other members reference them asymmetrically;
    the remaining tie classes are resolved by picking, among all orderings that permute members
    within their tie class, the lexicographically-least full group serialization — a choice made on
    bytes only, never source order. Byte-identical candidates are genuinely automorphic and get
    their indices by binding name (names are erased from the bytes, so hash identity is unaffected).
    Groups needing more than 5040 candidate orderings are rejected (E0505). Group-hash invariance
    under source permutation is tested with a 3-cycle and an asymmetric-reference twin group.

    Floats are normalized before hashing so hash identity matches [Form.equal_ignoring_meta]: [-0.0]
    serializes as [+0.0] and every NaN as the quiet NaN bit pattern [0x7ff8000000000000].

    Inputs must be resolved: a leftover [Named] reference is E0501, a free local is E0502 (both
    indicate the caller skipped or ignored resolution). Names inside [deftype] and [defeffect] (type
    name, constructor names, field labels, operation names) are content and do hash — M0 treats
    declared types nominally. *)

(* Internal control flow only; never escapes this module. *)
exception Err of Diag.t

let err ?meta ~code fmt =
  Printf.ksprintf
    (fun msg -> raise (Err (Diag.error ?span:(Option.bind meta Meta.span) ~code msg)))
    fmt

(* --- primitive encoders (spec/serialization.md) --- *)

let tag buf b = Buffer.add_char buf (Char.chr b)

let rec varint buf n =
  if n < 0 then invalid_arg "varint: negative"
  else if n < 0x80 then Buffer.add_char buf (Char.chr n)
  else begin
    Buffer.add_char buf (Char.chr (0x80 lor (n land 0x7f)));
    varint buf (n lsr 7)
  end

let int64be buf (i : int64) =
  for shift = 7 downto 0 do
    Buffer.add_char buf
      (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical i (8 * shift)) 0xFFL)))
  done

let text buf s =
  varint buf (String.length s);
  Buffer.add_string buf s

let quiet_nan_bits = 0x7ff8000000000000L

let real_bits r =
  if Float.is_nan r then quiet_nan_bits
  else if r = 0.0 then 0L (* normalize -0.0 to +0.0, matching equal_ignoring_meta *)
  else Int64.bits_of_float r

(* raw digest bytes; length is fixed by HASH_V0 *)
let hash_bytes buf (h : Hash.t) = Buffer.add_string buf (Hash.to_raw h)

let lit buf = function
  | Kernel.LInt i ->
      tag buf 0x01;
      int64be buf (Int64.of_int i)
  | Kernel.LReal r ->
      tag buf 0x02;
      int64be buf (real_bits r)
  | Kernel.LText s ->
      tag buf 0x03;
      text buf s

let refkind_tag = function Kernel.Term -> 0x01 | Kernel.Con -> 0x02 | Kernel.Op -> 0x03

let the_hash ~meta ~what = function
  | Kernel.Hashed h -> h
  | Kernel.Named n -> err ~meta ~code:"E0501" "unresolved %s `%s` reached hashing" what n

(* --- environments --- *)

(* How GroupRef serializes: outside any defterm group it is an error; inside, indices are
   either erased (order-independent signatures during canonical ordering) or substituted with
   canonical indices. Both in-group modes range-check. *)
type group_ctx = No_group | Erase of int | Subst of int array

type env = {
  locals : string list; (* innermost first *)
  group : group_ctx;
  tyvars : string list;
  rowvars : string list;
  tyself : string option;
      (* the enclosing type/effect declaration's own name: a [TRef (Named self)] serializes
         as the self tag 0x37 (a recursive declaration cannot contain its own hash) *)
}

let empty_env = { locals = []; group = No_group; tyvars = []; rowvars = []; tyself = None }
let push vars env = { env with locals = List.rev vars @ env.locals }

let local_index env ~meta x =
  let rec go i = function
    | [] -> err ~meta ~code:"E0502" "unbound variable `%s` reached hashing" x
    | y :: _ when String.equal x y -> i
    | _ :: rest -> go (i + 1) rest
  in
  go 0 env.locals

(* Variables bound by a pattern, left-to-right (resolution already rejected duplicates). *)
let rec pat_vars (p : Kernel.pat) =
  match p.Kernel.it with
  | Kernel.PWild | Kernel.PLit _ -> []
  | Kernel.PVar x -> [ x ]
  | Kernel.PCon (_, ps) | Kernel.PTuple ps -> List.concat_map pat_vars ps
  | Kernel.PAs (x, inner) -> x :: pat_vars inner

(* --- serializers --- *)

let rec ser_expr buf env (e : Kernel.expr) =
  let meta = e.Kernel.meta in
  match e.Kernel.it with
  | Kernel.Lit l ->
      tag buf 0x01;
      lit buf l
  | Kernel.Var x ->
      tag buf 0x02;
      varint buf (local_index env ~meta x)
  | Kernel.Ref (h, k) ->
      tag buf 0x03;
      tag buf (refkind_tag k);
      hash_bytes buf h
  | Kernel.Lam (params, body) ->
      tag buf 0x04;
      varint buf (List.length params);
      List.iter (ser_pat buf env) params;
      ser_expr buf (push (List.concat_map pat_vars params) env) body
  | Kernel.App (fn, args) ->
      tag buf 0x05;
      ser_expr buf env fn;
      varint buf (List.length args);
      List.iter (ser_expr buf env) args
  | Kernel.Let { isrec; binder; value; body } ->
      tag buf 0x06;
      tag buf (if isrec then 0x01 else 0x00);
      ser_pat buf env binder;
      let bound = pat_vars binder in
      ser_expr buf (if isrec then push bound env else env) value;
      ser_expr buf (push bound env) body
  | Kernel.Match (scrutinee, clauses) ->
      tag buf 0x07;
      ser_expr buf env scrutinee;
      varint buf (List.length clauses);
      List.iter
        (fun { Kernel.cpat; cbody; _ } ->
          ser_pat buf env cpat;
          ser_expr buf (push (pat_vars cpat) env) cbody)
        clauses
  | Kernel.Tuple items ->
      tag buf 0x08;
      varint buf (List.length items);
      List.iter (ser_expr buf env) items
  | Kernel.Handle { body; ret = { rbinder; rbody; _ }; ops } ->
      tag buf 0x09;
      ser_expr buf env body;
      ser_pat buf env rbinder;
      ser_expr buf (push (pat_vars rbinder) env) rbody;
      varint buf (List.length ops);
      List.iter
        (fun { Kernel.op; params; resume; obody; ometa } ->
          hash_bytes buf (the_hash ~meta:ometa ~what:"operation" op);
          varint buf (List.length params);
          List.iter (ser_pat buf env) params;
          ser_expr buf (push (List.concat_map pat_vars params @ [ resume ]) env) obody)
        ops
  | Kernel.Quote payload ->
      tag buf 0x0A;
      ser_quoted buf env payload
  | Kernel.Unquote splice ->
      (* defensively kept: of_form never builds Unquote nodes (bare unquote is E0204 and
         quote payloads stay raw forms), but programmatic ASTs may *)
      tag buf 0x0B;
      ser_expr buf env splice
  | Kernel.Ann (subject, ty) ->
      tag buf 0x0C;
      ser_expr buf env subject;
      ser_ty buf env ty
  | Kernel.GroupRef i -> (
      tag buf 0x0D;
      match env.group with
      | No_group -> err ~meta ~code:"E0503" "`groupref` outside a defterm group"
      | Erase n ->
          if i < 0 || i >= n then err ~meta ~code:"E0503" "groupref index %d out of range" i
            (* index erased: order-independent signature *)
      | Subst subst ->
          if i < 0 || i >= Array.length subst then
            err ~meta ~code:"E0503" "groupref index %d out of range" i;
          varint buf subst.(i))

and ser_pat buf env (p : Kernel.pat) =
  match p.Kernel.it with
  | Kernel.PWild -> tag buf 0x20
  | Kernel.PVar _ -> tag buf 0x21 (* name erased; position is identity *)
  | Kernel.PLit l ->
      tag buf 0x22;
      lit buf l
  | Kernel.PCon (con, args) ->
      tag buf 0x23;
      hash_bytes buf (the_hash ~meta:p.Kernel.meta ~what:"constructor" con);
      varint buf (List.length args);
      List.iter (ser_pat buf env) args
  | Kernel.PTuple items ->
      tag buf 0x24;
      varint buf (List.length items);
      List.iter (ser_pat buf env) items
  | Kernel.PAs (_, inner) ->
      tag buf 0x25;
      ser_pat buf env inner

and ser_ty buf env (t : Kernel.ty) =
  let meta = t.Kernel.meta in
  match t.Kernel.it with
  | Kernel.TRef (Kernel.Named n) when env.tyself = Some n -> tag buf 0x37 (* self-reference *)
  | Kernel.TRef r ->
      tag buf 0x30;
      hash_bytes buf (the_hash ~meta ~what:"type" r)
  | Kernel.TVar a -> (
      tag buf 0x31;
      match List.find_index (String.equal a) env.tyvars with
      | Some i ->
          tag buf 0x01;
          varint buf i
      | None ->
          tag buf 0x00;
          text buf a)
  | Kernel.TApp (head, args) ->
      tag buf 0x32;
      ser_ty buf env head;
      varint buf (List.length args);
      List.iter (ser_ty buf env) args
  | Kernel.TArrow (params, row, result) ->
      tag buf 0x33;
      varint buf (List.length params);
      List.iter (ser_ty buf env) params;
      ser_row buf env row;
      ser_ty buf env result
  | Kernel.TTuple items ->
      tag buf 0x34;
      varint buf (List.length items);
      List.iter (ser_ty buf env) items
  | Kernel.TForall (tyvars, rowvars, body) ->
      tag buf 0x35;
      varint buf (List.length tyvars);
      varint buf (List.length rowvars);
      ser_ty buf
        { env with tyvars = List.rev tyvars @ env.tyvars; rowvars = List.rev rowvars @ env.rowvars }
        body

and ser_row buf env ({ Kernel.effects; rvar; wmeta } : Kernel.row) =
  tag buf 0x36;
  (* effect sets are unordered: serialize hashes sorted *)
  let hashes = List.map (the_hash ~meta:wmeta ~what:"effect") effects |> List.sort Hash.compare in
  varint buf (List.length hashes);
  List.iter (hash_bytes buf) hashes;
  match rvar with
  | None -> tag buf 0x00
  | Some v -> (
      tag buf 0x01;
      match List.find_index (String.equal v) env.rowvars with
      | Some i ->
          tag buf 0x01;
          varint buf i
      | None ->
          tag buf 0x00;
          text buf v)

(* Quoted payloads are data: serialize the raw triple (meta erased), except that LIVE
   (level-0) unquote splices serialize as expressions under the ambient environment, so
   locals captured by a splice stay alpha-invariant. Nested quotes raise the quasiquote
   level; their unquotes serialize as plain data forms. *)
and ser_quoted buf env ?(level = 0) (f : Form.t) =
  if f.Form.head = "unquote" && level = 0 then begin
    tag buf 0x51;
    match f.Form.args with
    | [ Form.F splice ] -> (
        match Kernel.expr_of_form splice with
        | Ok e -> ser_expr buf env e
        | Error ds -> raise (Err (List.hd ds)))
    | _ -> err ~meta:f.Form.meta ~code:"E0504" "malformed unquote reached hashing"
  end
  else begin
    let level =
      match f.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
    in
    tag buf 0x50;
    text buf f.Form.head;
    varint buf (List.length f.Form.args);
    List.iter
      (function
        | Form.F g -> ser_quoted buf env ~level g
        | Form.Int i ->
            tag buf 0x52;
            int64be buf (Int64.of_int i)
        | Form.Real r ->
            tag buf 0x53;
            int64be buf (real_bits r)
        | Form.Text s ->
            tag buf 0x54;
            text buf s
        | Form.Sym s ->
            tag buf 0x55;
            text buf s
        | Form.Hash h ->
            tag buf 0x56;
            hash_bytes buf h)
      f.Form.args
  end

let ser_binding buf env ({ Kernel.annot; value; _ } : Kernel.binding) =
  tag buf 0x43;
  (match annot with
  | None -> tag buf 0x00
  | Some t ->
      tag buf 0x01;
      ser_ty buf env t);
  ser_expr buf env value

(* --- hashing --- *)

let domain_hash prefix bytes = Hash.of_string (prefix ^ bytes)

(** Derived reference hashes (spec §6 rule 4): a constructor or operation is identified by its
    declaration's hash plus its ordinal. *)
let con_hash decl_hash ordinal =
  let buf = Buffer.create 40 in
  hash_bytes buf decl_hash;
  varint buf ordinal;
  domain_hash "C" (Buffer.contents buf)

let op_hash decl_hash ordinal =
  let buf = Buffer.create 40 in
  hash_bytes buf decl_hash;
  varint buf ordinal;
  domain_hash "O" (Buffer.contents buf)

(** [hash_expr e] hashes a resolved bare expression. *)
let hash_expr (e : Kernel.expr) : (Hash.t, Diag.t list) result =
  let buf = Buffer.create 256 in
  match ser_expr buf empty_env e with
  | () -> Ok (domain_hash "E" (Buffer.contents buf))
  | exception Err d -> Error [ d ]

(* Canonical member order and group serialization for a defterm group (module doc).

   Rank refinement alone cannot canonically order a graph: it propagates only OUT-references,
   so two members with identical bodies stay tied even when OTHER members reference them
   asymmetrically, and any source-based tie-break would leak source order into the hash.
   After refinement, the remaining tie classes are therefore resolved by exhaustive choice:
   among every ordering that permutes members only within their tie class, keep the one whose
   full group serialization is lexicographically least. That choice depends only on bytes,
   never on source order. Candidates with byte-identical serializations are genuinely
   automorphic; among those the members' binding names pick the assignment (names are erased
   from the bytes, so this cannot affect the hash — it only stabilizes which twin gets which
   member index). Groups whose tie classes would need more than 5040 candidate orderings are
   rejected with E0505 (pathologically symmetric; not expressible in reasonable code). *)
let canonicalize_group (bindings : Kernel.binding list) : int list * string =
  let n = List.length bindings in
  let members = Array.of_list bindings in
  let ser_with ctx i =
    let buf = Buffer.create 256 in
    ser_binding buf { empty_env with group = ctx } members.(i);
    Buffer.contents buf
  in
  (* round 0: indices erased *)
  let sigs = ref (Array.init n (fun i -> ser_with (Erase n) i)) in
  let ranks () =
    let sorted = List.sort_uniq String.compare (Array.to_list !sigs) in
    Array.map (fun s -> Option.get (List.find_index (String.equal s) sorted)) !sigs
  in
  let distinct a = Array.length a = List.length (List.sort_uniq compare (Array.to_list a)) in
  let r = ref (ranks ()) in
  let round = ref 0 in
  while (not (distinct !r)) && !round < n do
    (* refine: substitute previous rank classes for group indices *)
    sigs := Array.init n (fun i -> ser_with (Subst !r) i);
    r := ranks ();
    incr round
  done;
  let by_rank =
    List.sort
      (fun i j -> match compare !r.(i) !r.(j) with 0 -> compare i j | c -> c)
      (List.init n Fun.id)
  in
  (* consecutive members with equal ranks form tie classes *)
  let classes =
    List.fold_left
      (fun acc i ->
        match acc with
        | (j :: _ as cls) :: rest when !r.(j) = !r.(i) -> (i :: cls) :: rest
        | _ -> [ i ] :: acc)
      [] by_rank
    |> List.rev_map List.rev
  in
  let ser_candidate order =
    let subst = Array.make n 0 in
    List.iteri (fun canonical source -> subst.(source) <- canonical) order;
    let buf = Buffer.create 1024 in
    tag buf 0x40;
    varint buf n;
    List.iter
      (fun source -> ser_binding buf { empty_env with group = Subst subst } members.(source))
      order;
    Buffer.contents buf
  in
  if List.for_all (fun c -> List.length c = 1) classes then (by_rank, ser_candidate by_rank)
  else begin
    let rec factorial k = if k <= 1 then 1 else k * factorial (k - 1) in
    let candidate_count = List.fold_left (fun acc c -> acc * factorial (List.length c)) 1 classes in
    if candidate_count > 5040 then
      err ~code:"E0505"
        "this defterm group is too symmetric to order canonically (%d candidate orderings)"
        candidate_count;
    let rec permutations = function
      | [] -> [ [] ]
      | l ->
          List.concat_map
            (fun x -> List.map (fun p -> x :: p) (permutations (List.filter (( <> ) x) l)))
            l
    in
    let rec cartesian = function
      | [] -> [ [] ]
      | c :: rest ->
          let tails = cartesian rest in
          List.concat_map (fun perm -> List.map (fun t -> perm @ t) tails) (permutations c)
    in
    let names order = List.map (fun i -> members.(i).Kernel.bname) order in
    let best =
      List.fold_left
        (fun acc order ->
          let bytes = ser_candidate order in
          match acc with
          | None -> Some (order, bytes)
          | Some (border, bbytes) ->
              let c = String.compare bytes bbytes in
              if c < 0 || (c = 0 && compare (names order) (names border) < 0) then
                Some (order, bytes)
              else acc)
        None (cartesian classes)
    in
    match best with Some ob -> ob | None -> assert false (* cartesian is never empty *)
  end

type decl_hashes = { decl_hash : Hash.t; named : (string * Hash.t) list }
(** The hashes produced by one declaration: the declaration (or group) hash, plus derived hashes for
    defterm members, constructors, or operations, each with the name the store should index it
    under. *)

(** [hash_decl d] canonicalizes and hashes a resolved declaration. For a [defterm] the result lists
    each binding's member hash; for [deftype]/[defeffect] it lists the declaration hash under the
    type/effect name plus each constructor/operation's derived hash. *)
let hash_decl (d : Kernel.decl) : (decl_hashes, Diag.t list) result =
  try
    match d.Kernel.it with
    | Kernel.DefTerm bindings ->
        let order, group_bytes = canonicalize_group bindings in
        let members = Array.of_list bindings in
        let n = Array.length members in
        (* subst maps source index -> canonical index *)
        let subst = Array.make n 0 in
        List.iteri (fun canonical source -> subst.(source) <- canonical) order;
        let group_hash = domain_hash "G" group_bytes in
        let member_hash canonical_index =
          let b = Buffer.create 40 in
          hash_bytes b group_hash;
          varint b canonical_index;
          domain_hash "M" (Buffer.contents b)
        in
        Ok
          {
            decl_hash = group_hash;
            named =
              List.map
                (fun (source : int) -> (members.(source).Kernel.bname, member_hash subst.(source)))
                (List.init n Fun.id);
          }
    | Kernel.DefType { tname; tvars; cons } ->
        let buf = Buffer.create 512 in
        tag buf 0x41;
        text buf tname;
        varint buf (List.length tvars);
        let env = { empty_env with tyvars = List.rev tvars; tyself = Some tname } in
        varint buf (List.length cons);
        List.iter
          (fun { Kernel.con_name; fields; _ } ->
            tag buf 0x44;
            text buf con_name;
            varint buf (List.length fields);
            List.iter
              (fun { Kernel.label; fty; _ } ->
                tag buf 0x45;
                (match label with
                | None -> tag buf 0x00
                | Some l ->
                    tag buf 0x01;
                    text buf l);
                ser_ty buf env fty)
              fields)
          cons;
        let decl_hash = domain_hash "D" (Buffer.contents buf) in
        Ok
          {
            decl_hash;
            named =
              (tname, decl_hash)
              :: List.mapi (fun i { Kernel.con_name; _ } -> (con_name, con_hash decl_hash i)) cons;
          }
    | Kernel.DefEffect { ename; evars; ops } ->
        let buf = Buffer.create 512 in
        tag buf 0x42;
        text buf ename;
        varint buf (List.length evars);
        let env = { empty_env with tyvars = List.rev evars; tyself = Some ename } in
        varint buf (List.length ops);
        List.iter
          (fun { Kernel.op_name; op_params; op_result; _ } ->
            tag buf 0x46;
            text buf op_name;
            varint buf (List.length op_params);
            List.iter (ser_ty buf env) op_params;
            ser_ty buf env op_result)
          ops;
        let decl_hash = domain_hash "D" (Buffer.contents buf) in
        Ok
          {
            decl_hash;
            named =
              (ename, decl_hash)
              :: List.mapi (fun i { Kernel.op_name; _ } -> (op_name, op_hash decl_hash i)) ops;
          }
  with Err d -> Error [ d ]

(** [hash_top t] hashes either sort. Expressions report no named hashes. *)
let hash_top = function
  | Kernel.Expr e -> Result.map (fun h -> { decl_hash = h; named = [] }) (hash_expr e)
  | Kernel.Decl d -> hash_decl d
