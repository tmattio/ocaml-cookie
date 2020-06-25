module Date = Date
module Signer = Signer

type header = string * string

let header_of_string str =
  let len = String.length str in
  (* Check if the string is longer than "Cookie: "*)
  if len > 8 && String.sub str 0 8 |> String.lowercase_ascii = "cookie: " then
    Some ("Cookie", String.sub str 8 (len - 8))
    (* Check if the string is longer than "Set-Cookie: "*)
  else if
    len > 12 && String.sub str 0 12 |> String.lowercase_ascii = "set-cookie: "
  then Some ("Set-Cookie", String.sub str 12 (len - 12))
  else None

type expires = [ `Session | `MaxAge of int64 | `Date of Ptime.t ]

let expires_of_tuple (key, value) =
  String.lowercase_ascii key |> function
  | "max-age" -> Some (`MaxAge (Int64.of_string value))
  | "expires" ->
      Date.parse value |> Util.Option.of_result
      |> Util.Option.flat_map Ptime.of_date_time
      |> Util.Option.map (fun e -> `Date e)
  | _ -> None

type same_site = [ `None | `Strict | `Lax ]

type cookie = string * string

type t = {
  expires : expires;
  scope : Uri.t;
  same_site : same_site;
  secure : bool;
  http_only : bool;
  value : cookie;
}

let make ?(expires = `Session) ?(scope = Uri.empty) ?(same_site = `Lax)
    ?(secure = false) ?(http_only = true) ?sign_with (key, value) =
  let value =
    match sign_with with
    | None -> value
    | Some signer -> Signer.sign signer value
  in
  { expires; scope; same_site; secure; http_only; value = (key, value) }

let of_set_cookie_header ?origin:_ ((_, value) : header) =
  match Astring.String.cut ~sep:";" value with
  | None ->
      Util.Option.flat_map
        (fun (k, v) ->
          if String.trim k = "" then None
          else Some (make (String.trim k, String.trim v)))
        (Astring.String.cut value ~sep:"=")
  | Some (cookie, attrs) ->
      Util.Option.flat_map
        (fun (k, v) ->
          if k = "" then None
          else
            let value = (String.trim k, String.trim v) in
            let attrs =
              String.split_on_char ';' attrs
              |> List.map String.trim |> Attributes.list_to_map
            in
            let expires =
              Util.Option.first_some
                ( Attributes.AMap.find_opt "expires" attrs
                |> Util.Option.map (fun v -> ("expires", v)) )
                ( Attributes.AMap.find_opt "max-age" attrs
                |> Util.Option.map (fun v -> ("max-age", v)) )
              |> Util.Option.flat_map (fun a -> expires_of_tuple a)
            in
            let secure = Attributes.AMap.key_exists ~key:"secure" attrs in
            let http_only = Attributes.AMap.key_exists ~key:"http_only" attrs in
            let domain : string option =
              Attributes.AMap.find_opt "domain" attrs
            in
            let path = Attributes.AMap.find_opt "path" attrs in
            let scope =
              Uri.empty |> fun uri ->
              Uri.with_host uri domain |> fun uri ->
              Util.Option.map (Uri.with_path uri) path
              |> Util.Option.get_default ~default:uri
            in
            Some (make ?expires ~scope ~secure ~http_only value))
        (Astring.String.cut cookie ~sep:"=")

let to_set_cookie_header t =
  let v = Printf.sprintf "%s=%s" (fst t.value) (snd t.value) in
  let v =
    match Uri.path t.scope with
    | "" -> v
    | path -> Printf.sprintf "%s; Path=%s" v path
  in
  let v =
    match Uri.host t.scope with
    | None -> v
    | Some domain -> Printf.sprintf "%s; Domain=%s" v domain
  in
  let v =
    match t.expires with
    | `Date ptime ->
        Printf.sprintf "%s; Expires=%s" v
          (Ptime.to_date_time ptime |> Date.serialize)
    | `MaxAge max -> Printf.sprintf "%s; Max-Age=%s" v (Int64.to_string max)
    | `Session -> v
  in
  let v = if t.secure then Printf.sprintf "%s; Secure" v else v in
  let v = if t.http_only then Printf.sprintf "%s; HttpOnly" v else v in
  ("Set-Cookie", v)

let is_expired ?now t =
  match now with
  | None -> false
  | Some than -> (
      match t.expires with `Date e -> Ptime.is_earlier ~than e | _ -> false )

let is_not_expired ?now t = not (is_expired ?now t)

let is_too_old ?(elapsed = 0L) t =
  match t.expires with
  | `MaxAge max_age -> if max_age <= elapsed then true else false
  | _ -> false

let is_not_too_old ?(elapsed = 0L) t = not (is_too_old ~elapsed t)

let has_matching_domain ~scope t =
  match (Uri.host scope, Uri.host t.scope) with
  | Some domain, Some cookie_domain ->
      if
        String.contains cookie_domain '.'
        && ( Astring.String.is_suffix domain ~affix:cookie_domain
           || domain = cookie_domain )
      then true
      else false
  | _ -> true

let has_matching_path ~scope t =
  let cookie_path = Uri.path t.scope in
  if cookie_path = "/" then true
  else
    let path = Uri.path scope in
    Astring.String.is_prefix ~affix:cookie_path path || cookie_path = path

let is_secure ~scope t =
  match Uri.scheme scope with
  | Some "http" -> not t.secure
  | Some "https" -> true
  | _ -> not t.secure

let to_cookie_header ?now ?(elapsed = 0L) ?(scope = Uri.of_string "/") tl =
  if List.length tl = 0 then ("", "")
  else
    let idx = ref 0 in
    let cookie_map : string CookieMap.t =
      tl
      |> List.filter (fun c ->
             is_not_expired ?now c
             && has_matching_domain ~scope c
             && has_matching_path ~scope c && is_secure ~scope c)
      |> List.fold_left
           (fun m c ->
             idx := !idx + 1;
             let key, _value = c.value in

             CookieMap.update (!idx, key) (fun _ -> Some c) m)
           CookieMap.empty
      |> CookieMap.filter_value (is_not_too_old ~elapsed)
      |> CookieMap.map (fun c -> snd c.value)
    in

    if CookieMap.is_empty cookie_map then ("", "")
    else
      ( "Cookie",
        CookieMap.fold
          (fun (_idx, key) value l -> (key, value) :: l)
          cookie_map []
        |> List.rev
        |> List.map (fun (key, value) -> Printf.sprintf "%s=%s" key value)
        |> String.concat "; " )

let cookie_of_header ?signed_with cookie_key (key, value) =
  match key with
  | "Cookie" | "cookie" ->
      String.split_on_char ';' value
      |> List.map (Astring.String.cut ~sep:"=")
      |> ListLabels.find_map ~f:(function
           | Some (k, value) when k = cookie_key ->
               let value =
                 match signed_with with
                 | Some signer -> String.trim value |> Signer.unsign signer
                 | None -> Some (String.trim value)
               in
               Option.map (fun el -> (String.trim k, el)) value
           | _ -> None)
  | _ -> None

let cookie_of_headers ?signed_with cookie_key headers =
  let rec aux = function
    | [] -> None
    | header :: rest -> (
        match cookie_of_header ?signed_with cookie_key header with
        | Some cookie -> Some cookie
        | None -> aux rest )
  in
  aux headers

let cookies_of_header ?signed_with (key, value) =
  match key with
  | "Cookie" | "cookie" ->
      String.split_on_char ';' value
      |> List.map (Astring.String.cut ~sep:"=")
      |> Util.List.filter_map (function
           | Some (key, value) ->
               let value =
                 match signed_with with
                 | Some signer -> String.trim value |> Signer.unsign signer
                 | None -> Some (String.trim value)
               in
               Option.map (fun el -> (String.trim key, el)) value
           | None -> None)
  | _ -> []

let cookies_of_headers ?signed_with headers =
  ListLabels.fold_left headers ~init:[] ~f:(fun acc header ->
      let cookies = cookies_of_header ?signed_with header in
      acc @ cookies)
