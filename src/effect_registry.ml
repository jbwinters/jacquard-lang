type tier = Control | Uncertainty | Meta | World | Model | Governance | Concurrency
type risk = No_risk | Low | Medium | High | Special
type namespace = Official

type interface =
  | Released of { version : string; hash : Hash.t }
  | Reserved of { first_version : string }

type metadata = {
  display_name : string;
  index_name : string;
  namespace : namespace;
  tier : tier;
  default_risk : risk;
  reviewer_meaning : string;
  interface : interface;
}

type t = metadata list

type registration_error =
  | Missing_resolved_identity of string
  | Reserved_catalog_name of string
  | Duplicate_identity of Hash.t
  | Duplicate_display_name of string
  | Duplicate_index_name of string

let empty = []

let tier_name = function
  | Control -> "control"
  | Uncertainty -> "uncertainty"
  | Meta -> "meta"
  | World -> "world"
  | Model -> "model"
  | Governance -> "governance"
  | Concurrency -> "concurrency"

let risk_name = function
  | No_risk -> "none"
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Special -> "special"

let interface_hash metadata =
  match metadata.interface with Released { hash; _ } -> Some hash | Reserved _ -> None

let registration_error_to_string = function
  | Missing_resolved_identity name ->
      Printf.sprintf "reserved effect %s has no resolved interface identity" name
  | Reserved_catalog_name name ->
      Printf.sprintf "reserved catalog name %s cannot be retagged as released" name
  | Duplicate_identity hash ->
      Printf.sprintf "effect identity %s is already registered" (Hash.to_hex hash)
  | Duplicate_display_name name ->
      Printf.sprintf "blessed display name %s is already registered" name
  | Duplicate_index_name name -> Printf.sprintf "official index name %s is already registered" name

let reserved_catalog_names =
  [
    ("Choose", "choose");
    ("Env", "env");
    ("Pg", "pg");
    ("Blob", "blob");
    ("Serve", "serve");
    ("Crypto", "crypto");
    ("Log", "log");
    ("Approval", "approval");
    ("Audit", "audit");
    ("Secret", "secret");
    ("Judge", "judge");
    ("Async", "async");
    ("Channel", "channel");
  ]

let register registry metadata =
  match metadata.interface with
  | Reserved _ -> Error (Missing_resolved_identity metadata.display_name)
  | Released { hash; _ } ->
      let reserved_name =
        List.find_map
          (fun (display_name, index_name) ->
            if metadata.display_name = display_name then Some display_name
            else if metadata.index_name = index_name then Some index_name
            else None)
          reserved_catalog_names
      in
      if reserved_name <> None then Error (Reserved_catalog_name (Option.get reserved_name))
      else if
        List.exists
          (fun entry ->
            match entry.interface with
            | Released { hash = existing; _ } -> Hash.equal hash existing
            | Reserved _ -> false)
          registry
      then Error (Duplicate_identity hash)
      else if List.exists (fun entry -> entry.display_name = metadata.display_name) registry then
        Error (Duplicate_display_name metadata.display_name)
      else if List.exists (fun entry -> entry.index_name = metadata.index_name) registry then
        Error (Duplicate_index_name metadata.index_name)
      else Ok (metadata :: registry)

let released display_name index_name tier default_risk hash reviewer_meaning =
  let hash =
    match Hash.of_hex hash with
    | Some hash -> hash
    | None -> invalid_arg ("invalid frozen effect interface hash for " ^ display_name)
  in
  {
    display_name;
    index_name;
    namespace = Official;
    tier;
    default_risk;
    reviewer_meaning;
    interface = Released { version = "v1"; hash };
  }

let reserved display_name index_name tier default_risk reviewer_meaning =
  {
    display_name;
    index_name;
    namespace = Official;
    tier;
    default_risk;
    reviewer_meaning;
    interface = Reserved { first_version = "first-release" };
  }

let catalog =
  [
    released "Abort" "abort" Control No_risk
      "bfdfaeee39c6f5290ebea28e805bdeb92f448f1a1e0b9c47f3c70c53975b4375"
      "stop a computation without an error payload";
    released "Throw" "throw" Control No_risk
      "f236e77750a9c066fdff9220b81ab1ba6b6a5dd5226ab63dfd112f4b14aa504e"
      "stop a computation with a typed error payload";
    released "State" "state" Control No_risk
      "44a2946788e38fb6a734449880cce3d499aa5e2f876c5d9119773533b3d621a9"
      "read or replace handler-local state";
    released "Emit" "emit" Control No_risk
      "28afafc8cbec5108fa6103e4670269080373bc0d9a07b1f0f257861ef4b948f6"
      "append a value to a handler-defined stream";
    released "Dist" "dist" Uncertainty No_risk
      "5a31778adb668e471820541428a4d809f40206b231b2f9d40aeb36d5684415f0"
      "denote and condition finite possibilities";
    reserved "Choose" "choose" Uncertainty No_risk
      "explore one or more alternatives under a search handler";
    released "Fault" "fault" Uncertainty No_risk
      "0b7297f7a38573108de121c794c6be6471d9c43bd4749d435a3cd247e7d5f008"
      "explore whether a named failure site fires";
    released "Eval" "eval" Meta High
      "94f82f3c17d019d6ca5092b24f19d51ad40720d0accbc4c50641ade0ca056c24"
      "run code constructed or loaded at runtime";
    released "Console" "console" World Low
      "73e8a208eb7fadc43e3bd7aef1474884cf99ce86f8108ddf0e3baff0a74b3fc9"
      "talk to the process terminal";
    released "Clock" "clock" World Low
      "9041c22386c41541b6b6818bcb26f1aeb02ae8f0dce3fedbf5f411e4bff9eecb"
      "observe wall-clock milliseconds or wait";
    reserved "Env" "env" World Low "read one named process configuration value";
    released "Fs" "fs" World Medium
      "8ec13169c7181851364e55353232af8e3c7f5ee4a010fa3067fcf2058dd5ed84"
      "read or mutate the filesystem under the granted root handler";
    released "Net" "net" World High
      "be1aad7345c6215f227e63df6c7d05874a464f207599d4f5b85de8b0a6675b45"
      "reach a network endpoint through the granted handler";
    reserved "Pg" "pg" World High "issue a parameterized PostgreSQL query";
    reserved "Blob" "blob" World High "read or add immutable objects in configured blob storage";
    reserved "Serve" "serve" World High "receive and answer server requests";
    reserved "Crypto" "crypto" World High "use trusted cryptographic verification or system entropy";
    reserved "Log" "log" World Medium "emit a structured operational log entry";
    released "Infer" "infer" Model Medium
      "324b8f59279db3cabbfaaba430168717057cea8fc1435a11a1a9106e3e6fb4d8"
      "request a model completion selected by the handler";
    reserved "Approval" "approval" Governance Special
      "request hash-bound consent for an exact proposal";
    reserved "Audit" "audit" Governance Special
      "record governance evidence in an append-only stream";
    reserved "Secret" "secret" Governance Special
      "resolve opaque confidential material or explicitly expose it";
    reserved "Judge" "judge" Governance Special "assess a proposed call without performing it";
    reserved "Async" "async" Concurrency No_risk
      "schedule structured tasks while charging child effects to the parent row";
    reserved "Channel" "channel" Concurrency No_risk
      "communicate typed values between structured tasks";
  ]

let canonical =
  List.fold_left
    (fun registry metadata ->
      match metadata.interface with
      | Reserved _ -> registry
      | Released _ -> (
          match register registry metadata with
          | Ok registry -> registry
          | Error error -> invalid_arg (registration_error_to_string error)))
    empty catalog

let entries registry = List.sort (fun a b -> String.compare a.display_name b.display_name) registry

let find registry identity =
  List.find_opt
    (fun metadata ->
      match metadata.interface with
      | Released { hash; _ } -> Hash.equal identity hash
      | Reserved _ -> false)
    registry

let find_canonical identity = find canonical identity

type style = Plain | Ansi

let risk_color = function
  | No_risk -> "\027[90m"
  | Low -> "\027[32m"
  | Medium -> "\027[33m"
  | High -> "\027[31m"
  | Special -> "\027[35m"

let styled_risk style risk =
  let name = risk_name risk in
  match style with Plain -> name | Ansi -> risk_color risk ^ name ^ "\027[0m"

let render_blessed ?(style = Plain) ~name metadata =
  Printf.sprintf "%s [%s/%s] — %s" name (tier_name metadata.tier)
    (styled_risk style metadata.default_risk)
    metadata.reviewer_meaning

let render_metadata ?style metadata = render_blessed ?style ~name:metadata.display_name metadata

let qualify_user_hint ~name_hint identity =
  if
    String.starts_with ~prefix:"pk:" name_hint || String.starts_with ~prefix:"unpackaged:" name_hint
  then name_hint
  else Printf.sprintf "unpackaged:%s/%s" (String.sub (Hash.to_hex identity) 0 12) name_hint

let render_unknown ~name_hint identity =
  Printf.sprintf "%s [unrated user effect #%s]"
    (qualify_user_hint ~name_hint identity)
    (Hash.to_hex identity)

let render_resolved ?(style = Plain) ~name_hint identity =
  match find_canonical identity with
  | Some metadata -> render_blessed ~style ~name:metadata.display_name metadata
  | None -> render_unknown ~name_hint identity

let render_manifest_requirement ?(style = Plain) ~name_hint identity =
  match find_canonical identity with
  | Some metadata -> render_blessed ~style ~name:metadata.index_name metadata
  | None -> render_unknown ~name_hint identity
