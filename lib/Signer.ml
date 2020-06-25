type t = { secret : string; salt : string }

let make ?(salt = "salt.signer") secret = { secret; salt }

let constant_time_compare' a b init =
  let len = String.length a in
  let result = ref init in
  for i = 0 to len - 1 do
    result := !result lor Char.(compare a.[i] b.[i])
  done;
  !result = 0

let constant_time_compare a b =
  if String.length a <> String.length b then constant_time_compare' b b 1
  else constant_time_compare' a b 0

let derive_key t =
  Mirage_crypto.Hash.mac `SHA1
    ~key:(Cstruct.of_string t.secret)
    (Cstruct.of_string t.salt)

let get_signature t value =
  value |> Cstruct.of_string
  |> Mirage_crypto.Hash.mac `SHA1 ~key:(derive_key t)
  |> Cstruct.to_string |> Base64.encode_exn

let sign t data = String.concat "." [ data; get_signature t data ]

let verified t value signature =
  if constant_time_compare signature (get_signature t value) then Some value
  else None

let unsign t data =
  match String.split_on_char '.' data |> List.rev with
  | signature :: value ->
      let value = value |> List.rev |> String.concat "." in
      verified t value signature
  | _ -> None
