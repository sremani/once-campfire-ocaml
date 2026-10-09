(** Application endpoint registry. Keep the route table in [Route_catalog] as the
    source of matching order; each controller family owns only its handlers. *)

let endpoint name =
  match Controller_accounts.endpoint name with
  | Some _ as handler -> handler
  | None -> (match Controller_rooms.endpoint name with
      | Some _ as handler -> handler
      | None -> Controller_aux.endpoint name)
