-- Request validation with Result propagation (SX.29, D77). Each `let … = try`
-- step either yields its Ok payload or ends the enclosing block with the same
-- Err; the declared result type names the error type exactly.

type Field = | NameField | EmailField | AgeField

type Invalid = | Missing(field: Field) | Malformed(field: Field, text: Text) | TooYoung(age: Int)

type Request = | Request(name: Text, email: Text, age: Int)

required : (Field, Text) ->{} Result Invalid Text
required(field, raw) =
  if text.empty?(raw) then Err(Missing(field)) else Ok(raw)

email : (Text) ->{} Result Invalid Text
email(raw) = {
  let present = try required(EmailField, raw)
  if text.contains?(present, "@") then Ok(present) else Err(Malformed(EmailField, present))
}

age : (Text) ->{} Result Invalid Int
age(raw) = {
  let present = try required(AgeField, raw)
  match text.to-int(present) {
    | Some(years) -> if int.gte?(years, 18) then Ok(years) else Err(TooYoung(years))
    | None -> Err(Malformed(AgeField, present))
  }
}

validate : (Text, Text, Text) ->{} Result Invalid Request
validate(name-raw, email-raw, age-raw) = {
  let name = try required(NameField, name-raw)
  let address = try email(email-raw)
  let years = try age(age-raw)
  Ok(Request(name, address, years))
}

describe : (Result Invalid Request) ->{} Text
describe(result) =
  match result {
    | Ok(Request(name, _, years)) -> $"accepted {name}, {text.from-int(years)}"
    | Err(Missing(_)) -> "rejected: a field is missing"
    | Err(Malformed(_, text)) -> $"rejected: malformed {text}"
    | Err(TooYoung(years)) -> $"rejected: {text.from-int(years)} is under 18"
  }

describe(validate("Ada", "ada@example.org", "36"))

describe(validate("", "ada@example.org", "36"))

describe(validate("Ada", "ada.example.org", "36"))

describe(validate("Ada", "ada@example.org", "12"))
