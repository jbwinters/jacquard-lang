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

(* the prelude data types the Throw and Emit shapes return (design §11 A3.4); prerequisites of
   their registration *)
let result_type = frozen "result" "5552731cc63f81199617f3ecf4e4a8c14748c303d6ce78ce5b0f05f3026ad8db"
let list_type = frozen "list" "03b4cd180ed05bf70d8a3e401dfea0688a46cf6b8c6469fd8e7e013c9e603c81"

(** The shape of a scoped form (design §11 A3.4): State takes an initializer and returns the body's
    result; Throw returns [Result e a]; Emit returns the body's result paired with the emitted list.
*)
type shape = State | Throw | Emit

type family = {
  shape : shape;
  capability : Hash.t;  (** the capability type *)
  carrier : Hash.t;  (** its private constructor *)
  instance_effect : Hash.t;
  operations : Hash.t list;
  scoped : Hash.t;  (** the scoped term *)
}
(** One scoped instance family's frozen identities. *)

let state_family =
  {
    shape = State;
    capability = state_ref_type;
    carrier = state_ref_opaque_constructor;
    instance_effect = state_instance_effect;
    operations = [ state_get_at; state_put_at ];
    scoped = state_scoped;
  }

let families = [ state_family ]
let instance_operations = List.concat_map (fun family -> family.operations) families

(** [is_instance_operation hash] holds for an operation of a scoped instance effect. *)
let is_instance_operation hash = List.exists (Hash.equal hash) instance_operations

(** [is_private_carrier hash] holds for a capability type's private constructor. *)
let is_private_carrier hash = List.exists (fun family -> Hash.equal hash family.carrier) families

(** [family_identities family] lists every frozen identity of [family]. *)
let family_identities family =
  [ family.capability; family.carrier; family.instance_effect; family.scoped ] @ family.operations
