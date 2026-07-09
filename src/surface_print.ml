(** Canonical `.jac` printer boundary.

    The printer consumes validated kernel trees, not {!Surface_ast}; this makes it the definition of
    canonical surface text and lets parsed sugar lower locally before formatting. SS.2-SS.4 fill the
    implementation. *)

type lookup = Surface_name.kind -> Hash.t -> string option

let default_width = 100

(** [render_name] is the printer's sole D34 spelling boundary. *)
let render_name = Surface_name.render

let unavailable () : (string, Diag.t list) result =
  Error [ Diag.error ~code:"E1201" "surface printer is not implemented yet" ]

(** [print_top ?lookup ?width top] renders one validated kernel top-level item without a trailing
    newline. [lookup] supplies display names for hash references whose metadata lacks one. *)
let print_top ?(lookup : lookup option) ?(width = default_width) (_ : Kernel.top) :
    (string, Diag.t list) result =
  ignore lookup;
  ignore width;
  unavailable ()

(** [print_file] renders a complete canonical surface file with one trailing newline. *)
let print_file ?(lookup : lookup option) ?(width = default_width) (_ : Kernel.top list) :
    (string, Diag.t list) result =
  ignore lookup;
  ignore width;
  unavailable ()
