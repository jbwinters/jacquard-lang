-- Conformance kit fixtures for jacquard-host-v0.
-- Install once with `jacquard run fixtures.jac --store DIR`; kit.json records
-- the resulting identities and binds them to the synthetic HB.1 vectors.
once effect KitWorld where {
  send : (Text) -> Text
}

kit-ready : () ->{} ()
kit-ready() = ()

kit-echo : (Text) ->{KitWorld} Text
kit-echo(body) = send(body)

kit-twice : (Text) ->{KitWorld} Text
kit-twice(body) = send(send(body))

kit-double : (Int) ->{} Int
kit-double(n) = mul(n, 2)

kit-fail : (Int) ->{} Int
kit-fail(n) = div(n, 0)
