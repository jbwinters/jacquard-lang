-- A signup request as an opaque type: holding a ReqValid proves that its fields
-- passed req.validate, so later code never re-checks them. The reasons for a
-- refusal are an ordinary transparent type that clients may match on.
opaque type ReqValid = ReqValid(name: Text, email: Text, age: Int)

type ReqInvalid = | BlankName | BadEmail(email: Text) | AgeOutOfRange(age: Int)

req.validate(name, email, age) =
  if text.empty?(text.trim(name)) then Err(BlankName)
  else if bool.not(text.contains?(email, "@")) then Err(BadEmail(email))
  else if bool.not(int.between?(age, 13, 130)) then Err(AgeOutOfRange(age))
  else Ok(ReqValid(text.trim(name), email, age))

req.name(r) = match r { | ReqValid(name, _, _) -> name }

req.email(r) = match r { | ReqValid(_, email, _) -> email }

req.age(r) = match r { | ReqValid(_, _, age) -> age }

req.reason(invalid) =
  match invalid {
    | BlankName -> "the name is blank"
    | BadEmail(email) -> text.concat("the email has no @: ", email)
    | AgeOutOfRange(age) -> text.concat("the age is outside 13..130: ", text.from-int(age))
  }
