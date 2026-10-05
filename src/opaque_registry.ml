(* TYPE.1: the constructors of opaque types this process has indexed, with their type names. A
   constructor's identity derives from its declaration's bytes, which include the opaque marker, so
   membership is a fact about the hash itself and holds across every store. *)

let table : (Hash.t, string) Hashtbl.t = Hashtbl.create 16
let register con type_name = Hashtbl.replace table con type_name
let type_of con = Hashtbl.find_opt table con
