(** Frozen identities for the relational-warp carrier.

    These hashes keep the checker-internal [VaryWorld] refinement nominal: a user declaration with
    the same spelling or shape does not acquire privileged type behavior. *)

exception Bug_invalid_relational_hash of string

let hash_of_frozen label encoded =
  match Hash.of_hex encoded with
  | Some hash -> hash
  | None ->
      raise
        (Bug_invalid_relational_hash
           (Printf.sprintf "malformed frozen relational-warp %s hash" label))

let variation_type =
  hash_of_frozen "Variation type" "82890e1e544bec8d442d4a3c0d8f35de01e80b9e5749d89212f7241721ec2193"

let vary_world_constructor =
  hash_of_frozen "VaryWorld constructor"
    "c5fe486cc166773ae5372fb4c20635e640d24641597ea62847ae3787ca88654b"

(** [is_vary_world_constructor ~type_hash ~constructor_hash] holds only for the frozen prelude
    declaration and its [VaryWorld] constructor. *)
let is_vary_world_constructor ~type_hash ~constructor_hash =
  Hash.equal type_hash variation_type && Hash.equal constructor_hash vary_world_constructor
