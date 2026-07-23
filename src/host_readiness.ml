type registration = { id : int; task : Concurrency_contract.task_id }

type entry = {
  registration : registration;
  handle : Scheduler_core.handle;
  descriptor : Unix.file_descr;
}

type descriptor_ops = {
  duplicate : Unix.file_descr -> Unix.file_descr;
  close : Unix.file_descr -> unit;
  poll_readable : Unix.file_descr list -> Unix.file_descr list;
}

type ('resume, 'value) t = {
  scheduler : ('resume, 'value) Scheduler_core.t;
  descriptor_ops : descriptor_ops;
  mutable next_id : int;
  mutable entries : entry list;
  mutable closed : bool;
}

type wake_result = { awakened : Scheduler_core.handle list; cleanup_diagnostics : Diag.t list }

type poll_result = {
  awakened : Scheduler_core.handle list;
  decisions : registration list;
  cleanup_diagnostics : Diag.t list;
}

let diagnostic cause =
  Diag.error ~domain:Concurrency ~code:"E0908"
    ~summary:"The internal host-readiness lifecycle is invalid." ~cause
    ~next_step:"Discard the stale readiness decision and recreate the structured scheduler scope."
    ~contrast:None ()

let error cause = Error [ diagnostic cause ]

let unix_descriptor_ops =
  {
    duplicate = (fun descriptor -> Unix.dup ~cloexec:true descriptor);
    close = Unix.close;
    poll_readable =
      (fun descriptors ->
        let readable, _, _ = Unix.select descriptors [] [] 0.0 in
        readable);
  }

let create ?(descriptor_ops = unix_descriptor_ops) scheduler =
  { scheduler; descriptor_ops; next_id = 0; entries = []; closed = false }

let registration_count registry = List.length registry.entries

let close_descriptor registry descriptor =
  match registry.descriptor_ops.close descriptor with
  | () -> Ok ()
  | exception Unix.Unix_error _ ->
      error "A host-readiness descriptor could not be released; ownership was still retired."

let retire registry entry =
  registry.entries <-
    List.filter (fun current -> current.registration.id <> entry.registration.id) registry.entries;
  close_descriptor registry entry.descriptor

let retire_matching registry predicate =
  let retiring, retained = List.partition predicate registry.entries in
  registry.entries <- retained;
  List.fold_left
    (fun result entry ->
      match (result, close_descriptor registry entry.descriptor) with
      | Error diagnostics, _ -> Error diagnostics
      | Ok (), Ok () -> Ok ()
      | Ok (), Error diagnostics -> Error diagnostics)
    (Ok ()) retiring

let next_registration registry task =
  if registry.next_id = max_int then error "Host-readiness registration identities are exhausted."
  else Ok { id = registry.next_id; task }

let register registry ~task ~descriptor ~resume =
  if registry.closed then error "A closed host-readiness registry cannot accept registrations."
  else
    Result.bind (Scheduler_core.id registry.scheduler task) (fun task_id ->
        Result.bind (next_registration registry task_id) (fun registration ->
            Result.bind
              (Scheduler_core.prepare_host_suspend Task_capability.runtime registry.scheduler task
                 ~registration:registration.id ~resume) (fun prepared ->
                match registry.descriptor_ops.duplicate descriptor with
                | duplicate ->
                    Scheduler_core.commit_host_suspend Task_capability.runtime prepared;
                    registry.next_id <- registry.next_id + 1;
                    registry.entries <-
                      registry.entries @ [ { registration; handle = task; descriptor = duplicate } ];
                    Ok registration
                | exception Unix.Unix_error _ ->
                    error "The supplied host-readiness descriptor could not be duplicated.")))

let find_exact registry registration =
  List.find_opt
    (fun entry ->
      entry.registration.id = registration.id
      && Concurrency_contract.compare_task_id entry.registration.task registration.task = 0)
    registry.entries

let wake registry entry =
  Result.bind
    (Scheduler_core.wake_host_readiness Task_capability.runtime registry.scheduler entry.handle
       ~registration:entry.registration.id) (fun () ->
      let cleanup_diagnostics =
        match retire registry entry with Ok () -> [] | Error diagnostics -> diagnostics
      in
      Ok (entry.handle, cleanup_diagnostics))

let reconcile registry =
  let no_longer_owned entry =
    match Scheduler_core.inspect registry.scheduler entry.handle with
    | Ok
        {
          Scheduler_core.lifecycle = Concurrency_contract.Suspended;
          suspension = Some (Scheduler_core.Host_readiness registration);
          owns_resume = true;
          _;
        } ->
        registration <> entry.registration.id
    | Ok _ -> true
    | Error _ -> true
  in
  retire_matching registry no_longer_owned

let poll_live registry =
  if registry.closed then error "A closed host-readiness registry cannot be polled."
  else
    Result.bind (reconcile registry) (fun () ->
        let descriptors = List.map (fun entry -> entry.descriptor) registry.entries in
        match registry.descriptor_ops.poll_readable descriptors with
        | readable ->
            let is_readable descriptor = List.exists (( = ) descriptor) readable in
            let ready = List.filter (fun entry -> is_readable entry.descriptor) registry.entries in
            let rec wake_all awakened decisions cleanup_diagnostics = function
              | [] ->
                  Ok
                    {
                      awakened = List.rev awakened;
                      decisions = List.rev decisions;
                      cleanup_diagnostics = List.rev cleanup_diagnostics;
                    }
              | entry :: rest ->
                  Result.bind (wake registry entry) (fun (handle, cleanup) ->
                      wake_all (handle :: awakened) (entry.registration :: decisions)
                        (List.rev_append cleanup cleanup_diagnostics)
                        rest)
            in
            wake_all [] [] [] ready
        | exception Unix.Unix_error _ -> error "Live host-readiness polling failed.")

let replay registry ~registrations =
  if registry.closed then error "A closed host-readiness registry cannot replay decisions."
  else
    Result.bind (reconcile registry) (fun () ->
        let rec consume awakened cleanup_diagnostics = function
          | [] ->
              Ok
                { awakened = List.rev awakened; cleanup_diagnostics = List.rev cleanup_diagnostics }
          | registration :: rest -> (
              match find_exact registry registration with
              | None -> error "A replayed host-readiness decision is stale or duplicate."
              | Some entry ->
                  Result.bind (wake registry entry) (fun (handle, cleanup) ->
                      consume (handle :: awakened)
                        (List.rev_append cleanup cleanup_diagnostics)
                        rest))
        in
        consume [] [] registrations)

let drop_all drop resumes =
  let first_exception = ref None in
  List.iter
    (fun resume ->
      match drop resume with
      | () -> ()
      | exception exn -> if Option.is_none !first_exception then first_exception := Some exn)
    resumes;
  Option.iter raise !first_exception

let cancel registry task ~drop =
  if registry.closed then error "A closed host-readiness registry cannot cancel tasks."
  else
    Result.bind (Scheduler_core.request_cancel registry.scheduler task) (fun () ->
        Result.bind
          (Scheduler_core.deliver_cancel registry.scheduler
             ~point:Concurrency_contract.Routed_effect task) (fun (awakened, resumes) ->
            let release = retire_matching registry (fun entry -> entry.handle == task) in
            drop_all drop resumes;
            let cleanup_diagnostics =
              match release with Ok () -> [] | Error diagnostics -> diagnostics
            in
            Ok { awakened; cleanup_diagnostics }))

let shutdown registry ~drop =
  if registry.closed then Ok ()
  else (
    registry.closed <- true;
    let release = retire_matching registry (fun _ -> true) in
    let resumes = Scheduler_core.close registry.scheduler in
    drop_all drop resumes;
    release)
