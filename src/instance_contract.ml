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

let throw_family =
  {
    shape = Throw;
    capability =
      frozen "throw-ref" "393b1fd3fed23fe932c542f08f147da2f2c1ba56fcc1baf9dda3a27179dc337d";
    carrier =
      frozen "throw-ref-opaque" "76f9120d1f63210f328e0412b575976cd6e8f7403e9f3f72c5af54fa0d600915";
    instance_effect =
      frozen "throw-instance" "95571f168a1bf5b202d5b6fa89cf2c612092eaea8163000d880a8b068be2f36d";
    operations =
      [ frozen "throw.throw-at" "2c2e1faf6052c0d01036770c0e1e9a93accd216ada42f87b9111e2d897da92a4" ];
    scoped =
      frozen "throw.scoped" "a71b34730d90d768f77e2a68069c8eae669b86072e08771d75dcad7751b36b2c";
  }

let emit_family =
  {
    shape = Emit;
    capability =
      frozen "emit-ref" "b7584505eacc0568b09056d97092945cb3d538f5e76835e8590de7cd5b51fbd5";
    carrier =
      frozen "emit-ref-opaque" "a763dfaf37f36d67fc875c1b390bad995cad617f182472176a36344ae0a52a0f";
    instance_effect =
      frozen "emit-instance" "0996f7760777d3b64f3998f911892175a0b15b4a3ec17378a80014cb5207d7fe";
    operations =
      [ frozen "emit.emit-at" "19209e295d92a67a62f83a004dd97cee88ef8b5aaba7b8d123633b4d6ed17dd2" ];
    scoped = frozen "emit.scoped" "cf2c896b613ff5d60fccb686b21cf01af2c2330f52b1227bc27e635bfd601f3c";
  }

let families = [ state_family; throw_family; emit_family ]
let instance_operations = List.concat_map (fun family -> family.operations) families

(** [is_instance_operation hash] holds for an operation of a scoped instance effect. *)
let is_instance_operation hash = List.exists (Hash.equal hash) instance_operations

(** [is_private_carrier hash] holds for a capability type's private constructor. *)
let is_private_carrier hash = List.exists (fun family -> Hash.equal hash family.carrier) families

(** [family_identities family] lists every frozen identity of [family]. *)
let family_identities family =
  [ family.capability; family.carrier; family.instance_effect; family.scoped ] @ family.operations

(* the hidden token builtins' marker members (design §12 A4.2): the native compiler binds the
   token intrinsics to exactly these hashes, never by name *)
let token_builtins =
  [
    ( frozen "instance.fresh-v0" "e148cc2fcadc1f54ce9d168c763074ea45a52c43a1fbc86dfd223ca0e8ca5572",
      "instance.fresh-v0" );
    ( frozen "instance.same-v0" "be8cdc305501d4d20b599fe43bbb1520bec8b22685262b185f3453cf0556d7d9",
      "instance.same-v0" );
  ]

(** [is_token_builtin_name name] holds for a hidden token builtin's marker name. *)
let is_token_builtin_name name =
  List.exists (fun (_, known) -> String.equal known name) token_builtins

(** [is_token_builtin hash] holds for a frozen token builtin marker member. *)
let is_token_builtin hash = List.exists (fun (known, _) -> Hash.equal known hash) token_builtins
