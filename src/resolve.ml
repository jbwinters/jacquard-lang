(** Name resolution (plan W1.4): parsed kernel to resolved kernel.

    Locals stay [Var] (lexical scoping over [lam] params, [let] binders, [match] clause patterns,
    handler op-clause params and resume names, and the [ret] binder). Free names look up the store's
    name index and become [Ref (hash, kind)], retaining the original name in meta under [name].
    Within a [defterm] group, members see each other; a member reference resolves to the group-local
    marker [GroupRef i] (source order), not a hash (spec §6).

    [Named] references in patterns ([pcon]), op clauses, types ([tref]) and rows ([eref]) resolve
    against the same index and must have the matching kind. [Quote] payloads are data and are left
    unresolved, except that every [(unquote e)] splice inside them is resolved (splices evaluate).

    The store dependency is the seam the plan calls out: resolution takes a {!names} record; W1.4
    tests it against an in-memory stub and W1.6's store provides the real one.

    Diagnostics (accumulated; resolution visits the whole tree): E0301 unknown name (with near-miss
    suggestions at edit distance <= 2), E0302 kind mismatch, E0303 duplicate binding name in a
    [defterm] group, E0304 duplicate variable in one pattern. *)

(** What a name in scope refers to. [KCon]/[KOp] hashes are the folded constructor/operation hashes
    (decl hash + ordinal, derived in W1.5). *)
type nkind = KTerm | KCon | KOp | KType | KEffect

type entry = { hash : Hash.t; kind : nkind }

type names = { lookup : string -> entry option; all_names : unit -> string list }
(** The resolver's view of a store: total name lookup plus enumeration for suggestions. *)

let empty_names = { lookup = (fun _ -> None); all_names = (fun () -> []) }

(** [of_alist entries] builds a stub index; the W1.6 store exposes the real one. *)
let of_alist alist =
  { lookup = (fun n -> List.assoc_opt n alist); all_names = (fun () -> List.map fst alist) }

let kind_to_string = function
  | KTerm -> "a term"
  | KCon -> "a constructor"
  | KOp -> "an effect operation"
  | KType -> "a type"
  | KEffect -> "an effect"

(* Damerau-free Levenshtein, capped: we only care whether d <= 2. *)
let edit_distance a b =
  let la = String.length a and lb = String.length b in
  if abs (la - lb) > 2 then 3
  else begin
    let prev = Array.init (lb + 1) Fun.id in
    let cur = Array.make (lb + 1) 0 in
    for i = 1 to la do
      cur.(0) <- i;
      for j = 1 to lb do
        let cost = if a.[i - 1] = b.[j - 1] then 0 else 1 in
        cur.(j) <- min (min (cur.(j - 1) + 1) (prev.(j) + 1)) (prev.(j - 1) + cost)
      done;
      Array.blit cur 0 prev 0 (lb + 1)
    done;
    prev.(lb)
  end

type state = { names : names; mutable diags : Diag.t list }

let report st d = st.diags <- d :: st.diags
let rec take n = function [] -> [] | x :: xs -> if n <= 0 then [] else x :: take (n - 1) xs

let suggest st ~locals name =
  let candidates =
    List.sort_uniq String.compare (locals @ st.names.all_names ())
    |> List.filter (fun c -> c <> name && edit_distance name c <= 2)
  in
  match candidates with
  | [] -> None
  | [ c ] -> Some (Printf.sprintf "did you mean `%s`?" c)
  | cs -> Some (Printf.sprintf "did you mean one of: %s?" (String.concat ", " (take 3 cs)))

let unknown st ~meta ~locals ~what name =
  report st
    (Diag.error ?span:(Meta.span meta) ?hint:(suggest st ~locals name) ~code:"E0301"
       (Printf.sprintf "unknown %s `%s`" what name))

let kind_mismatch st ~meta name ~expected ~got =
  report st
    (Diag.error ?span:(Meta.span meta) ~code:"E0302"
       (Printf.sprintf "`%s` is %s, but this position needs %s" name (kind_to_string got) expected))

(* Resolve a non-term reference position (pcon/opclause/tref/eref). *)
let resolve_gref st ~meta ~locals ~expected_kind ~expected_desc ~what (g : Kernel.gref) :
    Kernel.gref =
  match g with
  | Kernel.Hashed _ -> g
  | Kernel.Named n -> (
      match st.names.lookup n with
      | Some { hash; kind } when kind = expected_kind -> Kernel.Hashed hash
      | Some { kind; _ } ->
          kind_mismatch st ~meta n ~expected:expected_desc ~got:kind;
          g
      | None ->
          unknown st ~meta ~locals ~what n;
          g)

(* Variables bound by a pattern, in binding order; duplicates within one binder group are
   diagnosed (E0304). [seen] is shared across sibling patterns of one binding construct
   (n-ary lam params, opclause params + resume), so `(lam ((pvar x) (pvar x)) ...)` is
   rejected like a duplicate inside a single pattern. *)
let pat_vars_seen st seen (p : Kernel.pat) : string list =
  let acc = ref [] in
  let bind meta x =
    if Hashtbl.mem seen x then
      report st
        (Diag.error ?span:(Meta.span meta) ~code:"E0304"
           (Printf.sprintf "variable `%s` is bound more than once in this pattern" x))
    else begin
      Hashtbl.add seen x ();
      acc := x :: !acc
    end
  in
  let rec go (p : Kernel.pat) =
    match p.Kernel.it with
    | Kernel.PWild | Kernel.PLit _ -> ()
    | Kernel.PVar x -> bind p.Kernel.meta x
    | Kernel.PCon (_, ps) | Kernel.PTuple ps -> List.iter go ps
    | Kernel.PAs (x, inner) ->
        bind p.Kernel.meta x;
        go inner
  in
  go p;
  List.rev !acc

let pat_vars st p = pat_vars_seen st (Hashtbl.create 8) p

let pats_vars st ps =
  let seen = Hashtbl.create 8 in
  (seen, List.concat_map (pat_vars_seen st seen) ps)

let rec resolve_pat st ~locals (p : Kernel.pat) : Kernel.pat =
  let it =
    match p.Kernel.it with
    | (Kernel.PWild | Kernel.PVar _ | Kernel.PLit _) as it -> it
    | Kernel.PCon (con, ps) ->
        let con =
          resolve_gref st ~meta:p.Kernel.meta ~locals ~expected_kind:KCon
            ~expected_desc:"a constructor" ~what:"constructor" con
        in
        Kernel.PCon (con, List.map (resolve_pat st ~locals) ps)
    | Kernel.PTuple ps -> Kernel.PTuple (List.map (resolve_pat st ~locals) ps)
    | Kernel.PAs (x, inner) -> Kernel.PAs (x, resolve_pat st ~locals inner)
  in
  { p with Kernel.it }

(* [tyself] is the enclosing type/effect declaration's own name: a [tref] to it stays
   [Named] (a recursive type cannot contain its own hash; canonicalization serializes the
   self-reference with a dedicated tag, spec/serialization.md). *)
let rec resolve_ty st ~locals ~tyself (t : Kernel.ty) : Kernel.ty =
  let it =
    match t.Kernel.it with
    | Kernel.TRef (Kernel.Named n) when tyself = Some n -> Kernel.TRef (Kernel.Named n)
    | Kernel.TRef r ->
        Kernel.TRef
          (resolve_gref st ~meta:t.Kernel.meta ~locals ~expected_kind:KType ~expected_desc:"a type"
             ~what:"type" r)
    | Kernel.TVar _ as it -> it
    | Kernel.TApp (head, args) ->
        Kernel.TApp
          (resolve_ty st ~locals ~tyself head, List.map (resolve_ty st ~locals ~tyself) args)
    | Kernel.TArrow (params, row, result) ->
        Kernel.TArrow
          ( List.map (resolve_ty st ~locals ~tyself) params,
            resolve_row st ~locals row,
            resolve_ty st ~locals ~tyself result )
    | Kernel.TTuple items -> Kernel.TTuple (List.map (resolve_ty st ~locals ~tyself) items)
    | Kernel.TForall (tvs, rvs, body) ->
        Kernel.TForall (tvs, rvs, resolve_ty st ~locals ~tyself body)
  in
  { t with Kernel.it }

and resolve_row st ~locals (r : Kernel.row) : Kernel.row =
  {
    r with
    Kernel.effects =
      List.map
        (resolve_gref st ~meta:r.Kernel.wmeta ~locals ~expected_kind:KEffect
           ~expected_desc:"an effect" ~what:"effect")
        r.Kernel.effects;
  }

(* [group] maps defterm member names to their source-order index. *)
let rec resolve_expr_in st ~group ~locals (e : Kernel.expr) : Kernel.expr =
  let mk it = { e with Kernel.it } in
  match e.Kernel.it with
  | Kernel.Lit _ | Kernel.Ref _ | Kernel.GroupRef _ -> e
  | Kernel.Var x -> (
      if List.mem x locals then e
      else
        match List.assoc_opt x group with
        | Some i -> { Kernel.it = Kernel.GroupRef i; meta = Meta.with_name x e.Kernel.meta }
        | None -> (
            match st.names.lookup x with
            | Some { hash; kind = KTerm } ->
                {
                  Kernel.it = Kernel.Ref (hash, Kernel.Term);
                  meta = Meta.with_name x e.Kernel.meta;
                }
            | Some { hash; kind = KCon } ->
                { Kernel.it = Kernel.Ref (hash, Kernel.Con); meta = Meta.with_name x e.Kernel.meta }
            | Some { hash; kind = KOp } ->
                { Kernel.it = Kernel.Ref (hash, Kernel.Op); meta = Meta.with_name x e.Kernel.meta }
            | Some { kind; _ } ->
                kind_mismatch st ~meta:e.Kernel.meta x ~expected:"a value" ~got:kind;
                e
            | None ->
                (* sibling group members count as near-miss candidates too *)
                unknown st ~meta:e.Kernel.meta ~locals:(List.map fst group @ locals) ~what:"name" x;
                e))
  | Kernel.Lam (params, body) ->
      let _, bound = pats_vars st params in
      mk
        (Kernel.Lam
           ( List.map (resolve_pat st ~locals) params,
             resolve_expr_in st ~group ~locals:(bound @ locals) body ))
  | Kernel.App (fn, args) ->
      mk
        (Kernel.App
           (resolve_expr_in st ~group ~locals fn, List.map (resolve_expr_in st ~group ~locals) args))
  | Kernel.Let { isrec; binder; value; body } ->
      let bound = pat_vars st binder in
      let value_locals = if isrec then bound @ locals else locals in
      mk
        (Kernel.Let
           {
             isrec;
             binder = resolve_pat st ~locals binder;
             value = resolve_expr_in st ~group ~locals:value_locals value;
             body = resolve_expr_in st ~group ~locals:(bound @ locals) body;
           })
  | Kernel.Match (scrutinee, clauses) ->
      mk
        (Kernel.Match
           ( resolve_expr_in st ~group ~locals scrutinee,
             List.map
               (fun { Kernel.cpat; cbody; cmeta } ->
                 let bound = pat_vars st cpat in
                 {
                   Kernel.cpat = resolve_pat st ~locals cpat;
                   cbody = resolve_expr_in st ~group ~locals:(bound @ locals) cbody;
                   cmeta;
                 })
               clauses ))
  | Kernel.Tuple items -> mk (Kernel.Tuple (List.map (resolve_expr_in st ~group ~locals) items))
  | Kernel.Handle { body; ret = { rbinder; rbody; rmeta }; ops } ->
      let ret =
        let bound = pat_vars st rbinder in
        {
          Kernel.rbinder = resolve_pat st ~locals rbinder;
          rbody = resolve_expr_in st ~group ~locals:(bound @ locals) rbody;
          rmeta;
        }
      in
      let ops =
        List.map
          (fun { Kernel.op; params; resume; obody; ometa } ->
            let op =
              resolve_gref st ~meta:ometa ~locals ~expected_kind:KOp
                ~expected_desc:"an effect operation" ~what:"operation" op
            in
            let seen, bound = pats_vars st params in
            if Hashtbl.mem seen resume then
              report st
                (Diag.error ?span:(Meta.span ometa) ~code:"E0304"
                   (Printf.sprintf "resume name `%s` duplicates an op clause parameter" resume));
            {
              Kernel.op;
              params = List.map (resolve_pat st ~locals) params;
              resume;
              obody = resolve_expr_in st ~group ~locals:(resume :: (bound @ locals)) obody;
              ometa;
            })
          ops
      in
      mk (Kernel.Handle { body = resolve_expr_in st ~group ~locals body; ret; ops })
  | Kernel.Quote payload -> mk (Kernel.Quote (resolve_quote_payload st ~group ~locals payload))
  | Kernel.Unquote splice -> mk (Kernel.Unquote (resolve_expr_in st ~group ~locals splice))
  | Kernel.Ann (subject, ty) ->
      mk
        (Kernel.Ann
           (resolve_expr_in st ~group ~locals subject, resolve_ty st ~locals ~tyself:None ty))

(* Quoted code stays data; only LIVE (level-0) unquote splices resolve. Nested quotes raise
   the quasiquote level; their unquotes are data until the inner quote itself evaluates. *)
and resolve_quote_payload st ~group ~locals ?(level = 0) (f : Form.t) : Form.t =
  if f.Form.head = "unquote" && level = 0 then
    match f.Form.args with
    | [ Form.F splice ] -> (
        match Kernel.expr_of_form splice with
        | Ok e ->
            let resolved = resolve_expr_in st ~group ~locals e in
            { f with Form.args = [ Form.F (Kernel.expr_to_form resolved) ] }
        | Error ds ->
            List.iter (report st) ds;
            f)
    | _ -> f (* shape already rejected by validation *)
  else
    let level =
      match f.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
    in
    {
      f with
      Form.args =
        List.map
          (function
            | Form.F g -> Form.F (resolve_quote_payload st ~group ~locals ~level g) | a -> a)
          f.Form.args;
    }

let resolve_binding st ~group (b : Kernel.binding) : Kernel.binding =
  {
    b with
    Kernel.annot = Option.map (resolve_ty st ~locals:[] ~tyself:None) b.Kernel.annot;
    value = resolve_expr_in st ~group ~locals:[] b.Kernel.value;
  }

let resolve_decl_in st (d : Kernel.decl) : Kernel.decl =
  let it =
    match d.Kernel.it with
    | Kernel.DefTerm bindings ->
        let group = List.mapi (fun i b -> (b.Kernel.bname, i)) bindings in
        let seen = Hashtbl.create 8 in
        List.iter
          (fun b ->
            if Hashtbl.mem seen b.Kernel.bname then
              report st
                (Diag.error ?span:(Meta.span b.Kernel.bmeta) ~code:"E0303"
                   (Printf.sprintf "binding `%s` appears more than once in this group"
                      b.Kernel.bname))
            else Hashtbl.add seen b.Kernel.bname ())
          bindings;
        Kernel.DefTerm (List.map (resolve_binding st ~group) bindings)
    | Kernel.DefType { tname; tvars; cons } ->
        Kernel.DefType
          {
            tname;
            tvars;
            cons =
              List.map
                (fun c ->
                  {
                    c with
                    Kernel.fields =
                      List.map
                        (fun fl ->
                          {
                            fl with
                            Kernel.fty = resolve_ty st ~locals:[] ~tyself:(Some tname) fl.Kernel.fty;
                          })
                        c.Kernel.fields;
                  })
                cons;
          }
    | Kernel.DefEffect { ename; evars; ops } ->
        Kernel.DefEffect
          {
            ename;
            evars;
            ops =
              List.map
                (fun o ->
                  {
                    o with
                    Kernel.op_params =
                      List.map (resolve_ty st ~locals:[] ~tyself:(Some ename)) o.Kernel.op_params;
                    op_result = resolve_ty st ~locals:[] ~tyself:(Some ename) o.Kernel.op_result;
                  })
                ops;
          }
  in
  { d with Kernel.it }

let run st f x =
  let v = f st x in
  match List.rev st.diags with [] -> Ok v | ds -> Error ds

let fresh names = { names; diags = [] }

(** [resolve_expr names e] resolves a bare expression (no enclosing group). *)
let resolve_expr names (e : Kernel.expr) =
  run (fresh names) (fun st -> resolve_expr_in st ~group:[] ~locals:[]) e

(** [resolve_decl names d] resolves a declaration; [defterm] members see each other as [GroupRef]
    markers. *)
let resolve_decl names (d : Kernel.decl) = run (fresh names) resolve_decl_in d

(** [resolve names top] resolves either. *)
let resolve names (t : Kernel.top) =
  match t with
  | Kernel.Decl d -> Result.map (fun d -> Kernel.Decl d) (resolve_decl names d)
  | Kernel.Expr e -> Result.map (fun e -> Kernel.Expr e) (resolve_expr names e)
