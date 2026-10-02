(* TS.2 frozen identities of the State instance declarations (design
   docs/designs/scoped-effect-instances.md §10 A2.1). The evaluator, store, native compiler and
   checker key every instance rule on these hashes, like the Async and Channel contracts. *)

exception Bug_invalid_instance_hash of string

let frozen name hex =
  match Hash.of_hex hex with
  | Some hash -> hash
  | None -> raise (Bug_invalid_instance_hash ("malformed frozen instance hash: " ^ name))

let state_ref_type =
  frozen "state-ref" "5cb6e92ccbacf7c046b07f3f087ed7548562598a46a10fc3d75be78d1d82e351"

let state_ref_opaque_constructor =
  frozen "state-ref-opaque" "6479a109eaded4a975ecf1b0e4ef243de65222aaee824f9a5731f75249820d70"

let state_instance_effect =
  frozen "state-instance" "7f3c91f3118e9d7d28dc8c677cbf82a6753e5f39b2d83ee0c8e80fc3a1b78265"

let state_get_at =
  frozen "state.get-at" "a741609b0a1d0dc81fad61d64695d4a49a51990d1d1f3f017aa25cbfe6ad5a50"

let state_put_at =
  frozen "state.put-at" "934e910456ffe2470d1609b02a15ca56b4d09944467150d58a8e5ab871b5db02"

let state_scoped =
  frozen "state.scoped" "b548fad24d2747db93d21b97739ebe7180e2deb2a138187a89de513d22778b9c"

let instance_operations = [ state_get_at; state_put_at ]

(** [is_instance_operation hash] holds for an operation of a scoped instance effect. *)
let is_instance_operation hash = List.exists (Hash.equal hash) instance_operations

(** [is_private_carrier hash] holds for a capability type's private constructor. *)
let is_private_carrier hash = Hash.equal hash state_ref_opaque_constructor
