(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt

let debug fmt =
  IrminLog.debug "HTTP" fmt

type 'a t = {
  input : IrminJSON.t -> 'a;
  output: 'a -> IrminJSON.t;
}

let some fn = {
  input  = IrminJSON.to_option fn.input;
  output = IrminJSON.of_option fn.output
}

let list fn = {
  input  = IrminJSON.to_list fn.input;
  output = IrminJSON.of_list fn.output;
}

let bool = {
  input  = IrminJSON.to_bool;
  output = IrminJSON.of_bool;
}

let path = {
  input  = IrminJSON.to_list IrminJSON.to_string;
  output = IrminJSON.of_list IrminJSON.of_string;
}

let unit = {
  input  = IrminJSON.to_unit;
  output = IrminJSON.of_unit;
}

module Server (S: Irmin.S) = struct

  let key = {
    input  = S.Key.of_json;
    output = S.Key.to_json;
  }

  let value = {
    input  = S.Value.of_json;
    output = S.Value.to_json;
  }

  let tree = {
    input  = S.Tree.of_json;
    output = S.Tree.to_json;
  }

  let revision = {
    input  = S.Revision.of_json;
    output = S.Revision.to_json;
  }

  let tag = {
    input  = S.Tag.of_json;
    output = S.Tag.to_json;
  }

  let respond body =
    Cohttp_lwt_unix.Server.respond_string ~status:`OK ~body ()

  let respond_json json =
    let json = `O [ "result", json ] in
    let body = IrminJSON.output json in
    Cohttp_lwt_unix.Server.respond_string ~status:`OK ~body ()

  let error msg =
    failwith ("error: " ^ msg)

  type t =
    | Leaf of (S.t -> IrminJSON.t list -> IrminJSON.t Lwt.t)
    | Node of (string * t) list

  let to_json t =
    let rec aux path acc = function
      | Leaf _ -> `String (String.concat "/" (List.rev path)) :: acc
      | Node c -> List.fold_left (fun acc (s,t) -> aux (s::path) acc t) acc c in
    `A (List.rev (aux [] [] t))

  let child c t: t =
    let error () =
      failwith ("Unknown action: " ^ c) in
    match t with
    | Leaf _ -> error ()
    | Node l ->
      try List.assoc c l
      with Not_found -> error ()

  let va t = t.S.value
  let tr t = t.S.tree
  let re t = t.S.revision
  let ta t = t.S.tag
  let t x = x

  let mk1 fn db i1 o =
    Leaf (fun t -> function
        | [x] ->
          let x = i1.input x in
          fn (db t) x >>= fun r ->
          return (o.output r)
        | []  -> error "Not enough arguments"
        | _   -> error "Too many arguments"
      )

  let mk2 fn db i1 i2 o =
    Leaf (fun t -> function
        | [x; y] ->
          let x = i1.input x in
          let y = i2.input y in
          fn (db t) x y >>= fun r ->
          return (o.output r)
        | [] | [_] -> error "Not enough arguments"
        | _        -> error "Too many arguments"
      )

  let value_store = Node [
      "read"  , mk1 S.Value.read va key   (some value);
      "mem"   , mk1 S.Value.mem  va key   bool;
      "list"  , mk1 S.Value.list va key   (list key);
      "add"   , mk1 S.Value.add  va value key;
  ]

  let tree_store = Node [
    "read"  , mk1 S.Tree.read tr key  (some tree);
    "mem"   , mk1 S.Tree.mem  tr key  bool;
    "list"  , mk1 S.Tree.list tr key  (list key);
    "add"   , mk1 S.Tree.add  tr tree key;
  ]

  let revision_store = Node [
    "read"  , mk1 S.Revision.read re key  (some revision);
    "mem"   , mk1 S.Revision.mem  re key  bool;
    "list"  , mk1 S.Revision.list re key  (list key);
    "add"   , mk1 S.Revision.add  re revision key;
  ]

  let tag_store = Node [
    "read"  , mk1 S.Tag.read   ta tag (some key);
    "mem"   , mk1 S.Tag.mem    ta tag bool;
    "list"  , mk1 S.Tag.list   ta tag (list tag);
    "update", mk2 S.Tag.update ta tag key unit;
    "remove", mk1 S.Tag.remove ta tag unit;
  ]

  let store = Node [
    "read"    , mk1 S.read    t path (some value);
    "mem"     , mk1 S.mem     t path bool;
    "list"    , mk1 S.list    t path (list path);
    "update"  , mk2 S.update  t path value unit;
    "remove"  , mk1 S.remove  t path unit;
    "value"   , value_store;
    "tree"    , tree_store;
    "revision", revision_store;
    "tag"     , tag_store;
  ]


  let process t ?body path =
    begin match body with
      | None   -> return_nil
      | Some b ->
        Cohttp_lwt_body.string_of_body (Some b) >>= fun b ->
        match IrminJSON.input b with
        | `A l -> return l
        | _    -> failwith "Wrong parameters"
    end >>= fun params ->
    let rec aux actions path =
      match path with
      | []      -> respond_json (to_json actions)
      | h::path ->
        match child h actions with
        | Leaf fn ->
          let params = match path with
            | [] -> params
            | _  -> (IrminJSON.of_strings path) :: params in
          fn t params >>= respond_json
        | actions -> aux actions path in
    aux store path

end

let servers = Hashtbl.create 8

let start_server (type t) (module S: Irmin.S with type t = t) (t:t) uri =
  let address = Uri.host_with_default ~default:"127.0.0.1" uri in
  let port = match Uri.port uri with
    | None   -> 8080
    | Some p -> p in
  let module Server = Server(S) in
  Printf.printf "Irminsule server listening on port %d ...\n%!" port;
  let callback conn_id ?body req =
    let path = Uri.path (Cohttp.Request.uri req) in
    Printf.printf "Request received: PATH=%s\n%!" path;
    let path = Re_str.split_delim (Re_str.regexp_string "/") path in
    let path = List.filter ((<>) "") path in
    Server.process t ?body path in
  let conn_closed conn_id () =
    Printf.eprintf "Connection %s closed!\n%!"
      (Cohttp_lwt_unix.Server.string_of_conn_id conn_id) in
  let config = { Cohttp_lwt_unix.Server.callback; conn_closed } in
  Cohttp_lwt_unix.Server.create ~address ~port config

let stop_server uri =
  debug "stop-server %s" (Uri.to_string uri);
  let address = Uri.host_with_default ~default:"127.0.0.1" uri in
  let port = match Uri.port uri with
    | None   -> 8080
    | Some p -> p in
  Cohttp_lwt_unix_net.build_sockaddr address (string_of_int port) >>=
  fun sockaddr ->
  let sock =
    Lwt_unix.socket
      (Unix.domain_of_sockaddr sockaddr)
      Unix.SOCK_STREAM 0 in
  Lwt_unix.close sock
