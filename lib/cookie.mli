module Signer : sig
  type t

  val make : ?salt:string -> string -> t
  (** [make secret] returns a new signer that will sign values with [secret] *)

  val sign : t -> string -> string
  (** [sign signer value] signs the string [value] with [signer] *)

  val unsign : t -> string -> string option
  (** [unsign signer value] unsigns a signed string [value] with [signer] *)
end

module Date : sig
  type date_time = Ptime.date * Ptime.time

  val parse : string -> (date_time, [> `Malformed ]) result

  val serialize : date_time -> string
end

type header = string * string
(** A standard header type used in many web frameworks like Httpaf and Cohttp *)

val header_of_string : string -> header option
(** parses ["Cookie: foo=bar"] into [("Cookie", "foo=bar")] *)

type expires = [ `Session | `MaxAge of int64 | `Date of Ptime.t ]
(** [expires] describes when a cookie will expire.
- [`Session] - nothing will be set
- [`MaxAge] - Max-Age will be set with the number
- [`Date] - Expires will be set with a date
*)

type same_site = [ `None | `Strict | `Lax ]

type cookie = string * string
(** The [cookie] type is a tuple of [(name, value)] *)

type t = {
  expires : expires;
  scope : Uri.t;
  same_site : same_site;
  secure : bool;
  http_only : bool;
  value : string * string;
}

val make :
  ?expires:expires ->
  ?scope:Uri.t ->
  ?same_site:same_site ->
  ?secure:bool ->
  ?http_only:bool ->
  ?sign_with:Signer.t ->
  cookie ->
  t
(** [make] creates a cookie, it will default to the following values:
- {!type:expires} - `Session
- {!type:scope} - None
- {!type:same_site} - `Lax
- [secure] - false
- [http_only] - true *)

val of_set_cookie_header : ?origin:string -> header -> t option

val to_set_cookie_header : t -> header

val to_cookie_header :
  ?now:Ptime.t -> ?elapsed:int64 -> ?scope:Uri.t -> t list -> header

val cookie_of_header :
  ?signed_with:Signer.t -> string -> header -> cookie option

val cookies_of_header : ?signed_with:Signer.t -> header -> cookie list

val cookie_of_headers :
  ?signed_with:Signer.t -> string -> header list -> cookie option

val cookies_of_headers : ?signed_with:Signer.t -> header list -> cookie list
