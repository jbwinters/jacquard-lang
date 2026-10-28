(* MODEL.1 model documents (jacquard-model-v1) and dependency records
   (jacquard-model-dependency-v1); docs/designs/model-dependencies.md. *)

let ( let* ) = Result.bind
let format_version = 1
let max_document_bytes = 65536
let max_input_bytes = 16 * 1024 * 1024

let diagnostic ~code cause =
  let summary, next_step =
    match code with
    | "E1800" ->
        ( "The model document is malformed.",
          "Write the document as `docs/designs/model-dependencies.md` describes." )
    | "E1801" -> ("A model document name is declared twice.", "Give each declaration its own name.")
    | "E1802" ->
        ( "A result argument does not name exactly one assumption, input, or exported term.",
          "Declare the name, rename the clashing declaration, or export the term from the source."
        )
    | "E1803" ->
        ( "An assumption is not closed literal data.",
          "Write the assumption as a literal or a constructor applied to literals." )
    | "E1804" ->
        ( "A file the model document names cannot be used.",
          "Check that the file exists, is a regular file within the size limit, and is valid." )
    | "E1805" ->
        ( "A result's entry cannot be applied to its arguments.",
          "Name an exported term and pass arguments of its parameter types." )
    | _ -> raise (Diag.Bug_invalid_diagnostic ("unknown model document code " ^ code))
  in
  Diag.error ~domain:Diag.Project ~code ~summary ~cause ~next_step ~contrast:None ()

let refuse ~code fmt = Printf.ksprintf (fun cause -> Error [ diagnostic ~code cause ]) fmt

(* --- documents --- *)

type driver = Run | Enumerate of { max_branches : int } | Lw of { seed : int; samples : int }
type argument = Named of string | Inline of string

type result_decl = {
  r_name : string;
  r_entry : string;
  r_arguments : argument list;
  r_driver : driver;
  r_fuel : int;
  r_line : int;
}

type t = {
  source : string;
  policy : string option;
  assumptions : (string * string * int) list;
  inputs : (string * string * int) list;
  results : result_decl list;
}

let is_digit c = c >= '0' && c <= '9'
let all p s = String.for_all p s

(* canonical decimal: no sign, no leading zero *)
let natural s =
  if s <> "" && all is_digit s && (s = "0" || s.[0] <> '0') then int_of_string_opt s else None

let positive s = match natural s with Some n when n > 0 -> Some n | _ -> None

let integer s =
  if String.length s > 1 && s.[0] = '-' then
    match natural (String.sub s 1 (String.length s - 1)) with
    | Some n when n > 0 -> Some (-n)
    | _ -> None
  else natural s

let valid_name s =
  s <> ""
  && s.[0] >= 'a'
  && s.[0] <= 'z'
  && all (fun c -> (c >= 'a' && c <= 'z') || is_digit c || c = '-' || c = '_' || c = '@') s

(* a term name or a path: one token, no comma *)
let valid_token s = s <> "" && all (fun c -> c > ' ' && c <> ',' && c <> '\x7f') s

(* -?D+(.D+)?([eE][-+]?D+)? *)
let numeric s =
  let n = String.length s in
  let digits i =
    let j = ref i in
    while !j < n && is_digit s.[!j] do
      incr j
    done;
    if !j = i then None else Some !j
  in
  let start = if n > 0 && s.[0] = '-' then 1 else 0 in
  match digits start with
  | None -> false
  | Some i -> (
      let i =
        if i < n && s.[i] = '.' then match digits (i + 1) with Some j -> Some j | None -> None
        else Some i
      in
      match i with
      | None -> false
      | Some i when i = n -> true
      | Some i when s.[i] = 'e' || s.[i] = 'E' -> (
          let k = if i + 1 < n && (s.[i + 1] = '-' || s.[i + 1] = '+') then i + 2 else i + 1 in
          match digits k with Some j -> j = n | None -> false)
      | Some _ -> false)

let words line = List.filter (fun w -> w <> "") (String.split_on_char ' ' line)

(* key=value settings, each required exactly once *)
let settings ~line ~what keys words =
  let rec go acc = function
    | [] -> (
        match List.find_opt (fun k -> not (List.mem_assoc k acc)) keys with
        | Some k -> refuse ~code:"E1800" "line %d: %s needs %s=" line what k
        | None -> Ok acc)
    | w :: rest -> (
        match String.index_opt w '=' with
        | Some i ->
            let k = String.sub w 0 i and v = String.sub w (i + 1) (String.length w - i - 1) in
            if not (List.mem k keys) then
              refuse ~code:"E1800" "line %d: %s has no setting %S" line what k
            else if List.mem_assoc k acc then
              refuse ~code:"E1800" "line %d: %s repeats the setting %s" line what k
            else go ((k, v) :: acc) rest
        | None -> refuse ~code:"E1800" "line %d: expected a key=value setting, got %S" line w)
  in
  go [] words

let setting ~line parse settings key =
  match parse (List.assoc key settings) with
  | Some v -> Ok v
  | None ->
      refuse ~code:"E1800" "line %d: %s=%s is not a canonical number" line key
        (List.assoc key settings)

let parse_driver ~line words =
  match words with
  | "run" :: rest ->
      let* s = settings ~line ~what:"driver run" [ "fuel" ] rest in
      let* fuel = setting ~line positive s "fuel" in
      Ok (Run, fuel)
  | "enumerate" :: rest ->
      let* s = settings ~line ~what:"driver enumerate" [ "max-branches"; "fuel" ] rest in
      let* max_branches = setting ~line positive s "max-branches" in
      let* fuel = setting ~line positive s "fuel" in
      Ok (Enumerate { max_branches }, fuel)
  | "lw" :: rest ->
      let* s = settings ~line ~what:"driver lw" [ "seed"; "samples"; "fuel" ] rest in
      let* seed = setting ~line integer s "seed" in
      let* samples = setting ~line positive s "samples" in
      let* fuel = setting ~line positive s "fuel" in
      Ok (Lw { seed; samples }, fuel)
  | other :: _ -> refuse ~code:"E1800" "line %d: unknown driver %S (run, enumerate, lw)" line other
  | [] -> refuse ~code:"E1800" "line %d: the driver is missing" line

let parse_arguments ~line = function
  | "none" -> Ok []
  | text ->
      let items = String.split_on_char ',' text in
      List.fold_right
        (fun item acc ->
          let* acc = acc in
          if numeric item then Ok (Inline item :: acc)
          else if valid_token item then Ok (Named item :: acc)
          else
            refuse ~code:"E1800" "line %d: argument %S is not a name or a numeric literal" line item)
        items (Ok [])

let parse_result ~line = function
  | name :: "entry" :: entry :: "args" :: args :: "driver" :: driver ->
      if not (valid_name name) then refuse ~code:"E1800" "line %d: invalid result name %S" line name
      else if not (valid_token entry) then
        refuse ~code:"E1800" "line %d: invalid entry name %S" line entry
      else
        let* r_arguments = parse_arguments ~line args in
        let* r_driver, r_fuel = parse_driver ~line driver in
        Ok { r_name = name; r_entry = entry; r_arguments; r_driver; r_fuel; r_line = line }
  | _ ->
      refuse ~code:"E1800" "line %d: expected `result NAME entry TERM args ARGS driver DRIVER ...`"
        line

let parse ~file text =
  let header = Printf.sprintf "jacquard-model format=%d" format_version in
  if String.length text > max_document_bytes then
    refuse ~code:"E1800" "%s is larger than %d bytes" file max_document_bytes
  else if not (String.is_valid_utf_8 text) then refuse ~code:"E1800" "%s is not UTF-8" file
  else if String.contains text '\r' then
    refuse ~code:"E1800" "%s contains a carriage return; use LF line endings" file
  else
    match String.split_on_char '\n' text with
    | first :: lines when first = header ->
        let empty = { source = ""; policy = None; assumptions = []; inputs = []; results = [] } in
        let names = Hashtbl.create 16 in
        let declare line name k =
          if Hashtbl.mem names name then
            refuse ~code:"E1801" "line %d: %S is already declared on line %d" line name
              (Hashtbl.find names name)
          else (
            Hashtbl.add names name line;
            k ())
        in
        let rec go doc line = function
          | [] -> Ok doc
          | l :: rest when l = "" || l.[0] = '#' -> go doc (line + 1) rest
          | l :: rest -> (
              let next doc = go doc (line + 1) rest in
              match words l with
              | [ "source"; path ] when valid_token path ->
                  if doc.source <> "" then refuse ~code:"E1800" "line %d: a second source line" line
                  else next { doc with source = path }
              | [ "policy"; path ] when valid_token path ->
                  if doc.policy <> None then
                    refuse ~code:"E1800" "line %d: a second policy line" line
                  else next { doc with policy = Some path }
              | "assumption" :: name :: "=" :: _ :: _ when valid_name name ->
                  let marker = " = " in
                  let rec find i = if String.sub l i 3 = marker then i + 3 else find (i + 1) in
                  let expression = String.trim (String.sub l (find 0) (String.length l - find 0)) in
                  declare line name (fun () ->
                      next { doc with assumptions = doc.assumptions @ [ (name, expression, line) ] })
              | [ "input"; name; "text"; path ] when valid_name name && valid_token path ->
                  declare line name (fun () ->
                      next { doc with inputs = doc.inputs @ [ (name, path, line) ] })
              | "result" :: words ->
                  let* r = parse_result ~line words in
                  declare line r.r_name (fun () -> next { doc with results = doc.results @ [ r ] })
              | _ ->
                  refuse ~code:"E1800"
                    "line %d: expected a source, policy, assumption, input, or result line" line)
        in
        let* doc = go empty 2 lines in
        if doc.source = "" then refuse ~code:"E1800" "%s has no source line" file
        else if doc.results = [] then refuse ~code:"E1800" "%s declares no result" file
        else Ok doc
    | _ -> refuse ~code:"E1800" "%s must start with the line `%s`" file header

(* --- dependency records --- *)

type argument_identity =
  | Assumption of Hash.t
  | Input of Hash.t
  | Term of { term : Hash.t; signature : Hash.t }

type dependency = {
  entry : Hash.t;
  signature : Hash.t;
  labels : string option list option;
  prelude : string;
  core : string;
  driver : driver;
  fuel : int;
  policy : Hash.t;
  arguments : argument_identity list;
}

let record_header = "jacquard-model-dependency format=1"
let hex = Hash.to_hex

let labels_text = function
  | None -> "positional"
  | Some slots -> String.concat "," (List.map (function Some l -> l | None -> "_") slots)

let driver_text fuel = function
  | Run -> Printf.sprintf "driver run fuel=%d" fuel
  | Enumerate { max_branches } ->
      Printf.sprintf "driver enumerate max-branches=%d fuel=%d" max_branches fuel
  | Lw { seed; samples } -> Printf.sprintf "driver lw seed=%d samples=%d fuel=%d" seed samples fuel

let argument_text i = function
  | Assumption h -> Printf.sprintf "argument %d assumption %s" i (hex h)
  | Input h -> Printf.sprintf "argument %d input text %s" i (hex h)
  | Term { term; signature } ->
      Printf.sprintf "argument %d term %s signature %s" i (hex term) (hex signature)

let serialize_dependency d =
  String.concat ""
    (List.map
       (fun l -> l ^ "\n")
       ([
          record_header;
          Printf.sprintf "entry %s signature %s labels %s" (hex d.entry) (hex d.signature)
            (labels_text d.labels);
          Printf.sprintf
            "prelude %s core %s engine interpreter driver model-driver-v1 fuel-model fuel-v1"
            d.prelude d.core;
          driver_text d.fuel d.driver;
          Printf.sprintf "policy %s" (hex d.policy);
          Printf.sprintf "arguments %d" (List.length d.arguments);
        ]
       @ List.mapi argument_text d.arguments))

let key d = Hash.of_string ("jacquard-model-dependency-v1\000" ^ serialize_dependency d)

let parse_dependency bytes =
  let fail fmt = Printf.ksprintf (fun m -> Error m) fmt in
  let hash s = match Hash.of_canonical_hex s with Some h -> Ok h | None -> fail "bad hash %S" s in
  let token s = s <> "" && String.for_all (fun c -> c > ' ' && c < '\x7f') s in
  let parse_labels = function
    | "positional" -> Ok None
    | s ->
        let slots = String.split_on_char ',' s in
        if List.for_all (fun l -> l <> "" && token l) slots then
          Ok (Some (List.map (function "_" -> None | l -> Some l) slots))
        else fail "bad labels %S" s
  in
  let parse_argument i line =
    match words line with
    | [ "argument"; n; "assumption"; h ] when n = string_of_int i ->
        Result.map (fun h -> Assumption h) (hash h)
    | [ "argument"; n; "input"; "text"; h ] when n = string_of_int i ->
        Result.map (fun h -> Input h) (hash h)
    | [ "argument"; n; "term"; t; "signature"; s ] when n = string_of_int i ->
        let* term = hash t in
        let* signature = hash s in
        Ok (Term { term; signature })
    | _ -> fail "bad argument line %d" i
  in
  let lines = String.split_on_char '\n' bytes in
  let result =
    match lines with
    | header :: entry_line :: prelude_line :: driver_line :: policy_line :: count_line :: rest
      when header = record_header ->
        let* entry, signature, labels =
          match words entry_line with
          | [ "entry"; e; "signature"; s; "labels"; l ] ->
              let* e = hash e in
              let* s = hash s in
              let* l = parse_labels l in
              Ok (e, s, l)
          | _ -> fail "bad entry line"
        in
        let* prelude, core =
          match words prelude_line with
          | [
           "prelude";
           p;
           "core";
           c;
           "engine";
           "interpreter";
           "driver";
           "model-driver-v1";
           "fuel-model";
           "fuel-v1";
          ]
            when (p = "none" || Hash.of_canonical_hex p <> None) && token c ->
              Ok (p, c)
          | _ -> fail "bad prelude line"
        in
        let* driver, fuel =
          match words driver_line with
          | "driver" :: d -> (
              match parse_driver ~line:4 d with Ok v -> Ok v | Error _ -> fail "bad driver line")
          | _ -> fail "bad driver line"
        in
        let* policy =
          match words policy_line with [ "policy"; p ] -> hash p | _ -> fail "bad policy line"
        in
        let* count =
          match words count_line with
          | [ "arguments"; n ] -> (
              match natural n with Some n -> Ok n | None -> fail "bad argument count")
          | _ -> fail "bad argument count"
        in
        if List.length rest <> count + 1 || List.nth rest count <> "" then
          fail "expected %d argument lines and a final newline" count
        else
          let* arguments =
            List.fold_left
              (fun acc (i, line) ->
                let* acc = acc in
                let* a = parse_argument i line in
                Ok (a :: acc))
              (Ok [])
              (List.mapi (fun i l -> (i, l)) (List.filteri (fun i _ -> i < count) rest))
          in
          Ok
            {
              entry;
              signature;
              labels;
              prelude;
              core;
              driver;
              fuel;
              policy;
              arguments = List.rev arguments;
            }
    | _ -> fail "not a %s record" record_header
  in
  match result with
  | Ok d when serialize_dependency d = bytes -> Ok d
  | Ok _ -> fail "the record is not in canonical form"
  | Error _ as e -> e

let default_policy =
  match
    Observation_policy.make ~result:Observation_policy.Compare ~field_bytes:(1024 * 1024)
      ~unlisted:None ~interface:None []
  with
  | Ok p -> p
  | Error _ -> assert false

(* --- resolving a document against its source --- *)

type resolved = {
  decl : result_decl;
  dependency : dependency;
  application : Kernel.expr;
  world : Hash.t list;
}

type prepared = {
  artifact : Frontend.Checked.t;
  store : Store.t;
  checker : Check.ctx;
  policy : Observation_policy.t;
  resolved : resolved list;
}

let read_limited ~what path =
  match
    In_channel.with_open_bin path (fun ic ->
        let length = In_channel.length ic in
        if Int64.compare length (Int64.of_int max_input_bytes) > 0 then Error `Too_large
        else Ok (really_input_string ic (Int64.to_int length)))
  with
  | Ok bytes -> Ok bytes
  | Error `Too_large ->
      refuse ~code:"E1804" "%s %s is larger than %d bytes" what path max_input_bytes
  | exception Sys_error reason -> refuse ~code:"E1804" "%s cannot be read: %s" what reason

let read_regular ~what path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG; _ } -> read_limited ~what path
  | _ -> refuse ~code:"E1804" "%s %s is not a regular file" what path
  | exception Unix.Unix_error (e, _, _) ->
      refuse ~code:"E1804" "%s %s cannot be read: %s" what path (Unix.error_message e)

let node it = { Kernel.it; meta = Meta.empty }

(* closed literal data: literals, constructors, constructor applications and tuples over them *)
let rec literal_data (e : Kernel.expr) =
  match e.Kernel.it with
  | Kernel.Lit _ | Kernel.Ref (_, Kernel.Con) -> true
  | Kernel.App ({ Kernel.it = Kernel.Ref (_, Kernel.Con); _ }, args) | Kernel.Tuple args ->
      List.for_all literal_data args
  | Kernel.Ann (e, _) -> literal_data e
  | _ -> false

let resolve_assumption ~store ~checker ~line ~what text =
  let names = Store.names_view store in
  let wrap ds =
    Error
      (diagnostic ~code:"E1803" (Printf.sprintf "line %d: %s does not parse or resolve" line what)
      :: ds)
  in
  match Frontend.parse_tops ~syntax:Frontend.Surface ~names ~file:what text with
  | Error ds -> wrap ds
  | Ok ([ top ], _) -> (
      match Frontend.validate_parsed_top top with
      | Error ds -> wrap ds
      | Ok (Kernel.Decl _) -> refuse ~code:"E1803" "line %d: %s is a declaration" line what
      | Ok (Kernel.Expr e) -> (
          match Resolve.resolve_expr names e with
          | Error ds -> wrap ds
          | Ok e -> (
              let sealed =
                List.filter_map (Store.sealed_constructor store) (Store.top_refs (Kernel.Expr e))
              in
              match sealed with
              | (type_name, con_name, _) :: _ ->
                  refuse ~code:"E1803"
                    "line %d: %s uses `%s`, a sealed constructor of the opaque type `%s`" line what
                    con_name type_name
              | [] when not (literal_data e) ->
                  refuse ~code:"E1803"
                    "line %d: %s computes; only literals and constructors applied to them are \
                     allowed"
                    line what
              | [] -> (
                  match Check.check_top checker (Kernel.Expr e) with
                  | Error ds -> wrap ds
                  | Ok _ -> (
                      match Canon.hash_expr e with Ok h -> Ok (e, h) | Error ds -> wrap ds)))))
  | Ok _ -> refuse ~code:"E1803" "line %d: %s is not exactly one expression" line what

let check_source ~prelude_dir ~root ~file source =
  match Frontend.check ~prelude_dir ~root ~syntax:Frontend.Auto ~file source with
  | Error ds -> Error ds
  | Ok (Frontend.Recovered { diagnostics; _ }) -> Error diagnostics
  | Ok (Frontend.Checked artifact) ->
      let* store = Store.open_store root in
      let* checker = Frontend.make_checker store in
      Ok (artifact, store, checker)

let prelude_text artifact =
  match Frontend.Checked.prelude artifact with
  | None -> "none"
  | Some pairs ->
      hex (Hash.of_string (String.concat "\n" (List.map (fun (k, v) -> k ^ "=" ^ v) pairs)))

let signature_hash text = Hash.of_string ("jacquard-model-signature-v1\000" ^ text)

let prepare ~prelude_dir ~root ~file doc =
  let dir = Filename.dirname file in
  let path p = if Filename.is_relative p then Filename.concat dir p else p in
  let* source = read_regular ~what:"source" (path doc.source) in
  let* policy =
    match doc.policy with
    | None -> Ok default_policy
    | Some p -> (
        let* bytes = read_regular ~what:"policy" (path p) in
        match Observation_policy.parse bytes with
        | Ok policy -> Ok policy
        | Error ds ->
            Error (diagnostic ~code:"E1804" (Printf.sprintf "policy %s is not canonical" p) :: ds))
  in
  let* inputs =
    List.fold_left
      (fun acc (name, p, line) ->
        let* acc = acc in
        let* bytes = read_regular ~what:(Printf.sprintf "input %s (line %d)" name line) (path p) in
        if String.is_valid_utf_8 bytes then Ok ((name, bytes) :: acc)
        else refuse ~code:"E1804" "line %d: input %s (%s) is not UTF-8 text" line name p)
      (Ok []) doc.inputs
  in
  let* artifact, store, checker = check_source ~prelude_dir ~root ~file:(path doc.source) source in
  let interface = Frontend.Checked.interface artifact in
  let exported name = Interface.find interface name Resolve.KTerm in
  let* () =
    match
      List.find_opt (fun (name, _, _) -> exported name <> None) (doc.assumptions @ doc.inputs)
    with
    | Some (name, _, line) ->
        refuse ~code:"E1802" "line %d: %S is both declared here and an exported term of the source"
          line name
    | None -> Ok ()
  in
  let* assumptions =
    List.fold_left
      (fun acc (name, text, line) ->
        let* acc = acc in
        let* v =
          resolve_assumption ~store ~checker ~line ~what:(Printf.sprintf "assumption %s" name) text
        in
        Ok ((name, v) :: acc))
      (Ok []) doc.assumptions
  in
  let dist =
    match Prelude_identity.lookup_kind store "dist" Resolve.KEffect with
    | Some { Resolve.hash; _ } -> [ hash ]
    | None -> []
  in
  let always = Frontend.granted_effects store [] in
  let prelude = prelude_text artifact in
  let policy_identity = Observation_policy.identity policy in
  let resolve_result (r : result_decl) =
    let line = r.r_line in
    let* (export : Interface.export) =
      match exported r.r_entry with
      | Some e -> Ok e
      | None ->
          refuse ~code:"E1805" "line %d: result %s: `%s` is not an exported term of the source" line
            r.r_name r.r_entry
    in
    let* args =
      List.fold_left
        (fun acc a ->
          let* acc = acc in
          let* v =
            match a with
            | Inline text ->
                let* e, h =
                  resolve_assumption ~store ~checker ~line
                    ~what:(Printf.sprintf "inline argument %s" text)
                    text
                in
                Ok (e, Assumption h)
            | Named n -> (
                match List.assoc_opt n assumptions with
                | Some (e, h) -> Ok (e, Assumption h)
                | None -> (
                    match List.assoc_opt n inputs with
                    | Some bytes ->
                        Ok (node (Kernel.Lit (Kernel.LText bytes)), Input (Hash.of_string bytes))
                    | None -> (
                        if List.exists (fun (o : result_decl) -> o.r_name = n) doc.results then
                          refuse ~code:"E1802"
                            "line %d: result %s passes the result %s; results are not arguments in \
                             model-v1"
                            line r.r_name n
                        else
                          match exported n with
                          | Some t ->
                              Ok
                                ( node (Kernel.Ref (t.Interface.hash, Kernel.Term)),
                                  Term
                                    {
                                      term = t.Interface.hash;
                                      signature =
                                        signature_hash
                                          (Option.value t.Interface.signature ~default:"");
                                    } )
                          | None ->
                              refuse ~code:"E1802"
                                "line %d: result %s: %S is not an assumption, an input, or an \
                                 exported term"
                                line r.r_name n)))
          in
          Ok (v :: acc))
        (Ok []) r.r_arguments
    in
    let args = List.rev args in
    let application =
      node (Kernel.App (node (Kernel.Ref (export.Interface.hash, Kernel.Term)), List.map fst args))
    in
    let* row =
      match Check.check_top checker (Kernel.Expr application) with
      | Ok { Check.row; _ } -> Ok (Option.value row ~default:Types.empty_row)
      | Error ds ->
          Error
            (diagnostic ~code:"E1805"
               (Printf.sprintf "line %d: result %s: `%s` does not accept these arguments" line
                  r.r_name r.r_entry)
            :: ds)
    in
    let handled = always @ match r.r_driver with Run -> [] | Enumerate _ | Lw _ -> dist in
    let world =
      List.filter
        (fun h -> not (List.exists (Hash.equal h) handled))
        (Types.repr_row row).Types.effects
    in
    let dependency =
      {
        entry = export.Interface.hash;
        signature = signature_hash (Option.value export.Interface.signature ~default:"");
        labels = export.Interface.labels;
        prelude;
        core = Version.version;
        driver = r.r_driver;
        fuel = r.r_fuel;
        policy = policy_identity;
        arguments = List.map snd args;
      }
    in
    Ok { decl = r; dependency; application; world }
  in
  let* resolved =
    List.fold_left
      (fun acc r ->
        let* acc = acc in
        let* v = resolve_result r in
        Ok (v :: acc))
      (Ok []) doc.results
  in
  Ok { artifact; store; checker; policy; resolved = List.rev resolved }
