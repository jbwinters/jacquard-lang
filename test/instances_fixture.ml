(* TS.2 slice 1 test fixture: a State-shaped scoped instance effect, declared in a test store and
   registered on test checker contexts only (design docs/designs/scoped-effect-instances.md §9
   A1.10). Production contexts never register it. *)

open Jacquard

let source =
  {|(deftype state-ref ((tvar s)) (con state-ref-opaque))
(defeffect state-instance ((tvar s))
  (op get-at ((tapp (tref state-ref) (tvar s))) (tvar s))
  (op put-at ((tapp (tref state-ref) (tvar s)) (tvar s)) (ttuple)))
(defterm ((binding state.scoped () (lam ((pvar init) (pvar f)) (var init)))))
|}

(* Install [source] into [store], checking each declaration with [ctx] first. *)
let install store ctx =
  match Reader.parse_string ~file:"instances-fixture.jqd" source with
  | Error diagnostics -> Error diagnostics
  | Ok forms ->
      List.fold_left
        (fun installed form ->
          Result.bind installed (fun () ->
              Result.bind (Kernel.of_form form) (fun top ->
                  Result.bind
                    (Resolve.resolve (Store.names_view store) top)
                    (fun resolved ->
                      Result.bind (Check.check_top ctx resolved) (fun _ ->
                          match resolved with
                          | Kernel.Decl declaration ->
                              Result.map (fun _ -> ()) (Store.put_decl store declaration)
                          | Kernel.Expr _ -> Ok ())))))
        (Ok ()) forms

let hash store kind name =
  match Store.lookup_kind store name kind with
  | Some { Resolve.hash; _ } -> hash
  | None -> failwith ("instances fixture: missing " ^ name)

(** The registration for the installed fixture. *)
let registration store : Check.instance_registration =
  {
    scoped = hash store Resolve.KTerm "state.scoped";
    instance_effect = hash store Resolve.KEffect "state-instance";
    capability = hash store Resolve.KType "state-ref";
    operations = [ hash store Resolve.KOp "get-at"; hash store Resolve.KOp "put-at" ];
    callback_position = 1;
  }

(** [install_and_register store ctx] installs the fixture and registers it on [ctx]. *)
let install_and_register store ctx =
  Result.map (fun () -> Check.register_instances ctx [ registration store ]) (install store ctx)
