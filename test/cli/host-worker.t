Opt-in serial host worker over the stdio-u32-json-v0 carrier (HB.2c). A frame
is a four-byte big-endian length followed by one JSON object, so the helpers
below frame scripted host input and unframe Core output for readability.
Store identities are replaced by names in the transcript; the frames
themselves carry the exact 64-digit hashes.

  $ export JACQUARD_PRELUDE=../../prelude
  $ frame() {
  >   n=$(printf '%s' "$1" | wc -c)
  >   printf "\\000\\000\\$(printf '%03o' $((n / 256)))\\$(printf '%03o' $((n % 256)))"
  >   printf '%s' "$1"
  > }
  $ unframe() {
  >   while :; do
  >     h=$(dd bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
  >     [ -z "$h" ] && break
  >     dd bs=1 count=$((0x$h)) 2>/dev/null
  >     echo
  >   done
  > }

The host populates a local store once; the worker reopens it without
reloading the prelude.

  $ cat > decls.jac <<'EOF'
  > once effect World where {
  >   send : (Text) -> Text
  > }
  > double : (Int) ->{} Int
  > double(n) = mul(n, 2)
  > echo : (Text) ->{World} Text
  > echo(body) = send(body)
  > EOF
  $ jacquard run decls.jac --store store
  $ INT=$(sed -n 's/^(named int type #\(.*\))$/\1/p' store/names.jqd)
  $ TEXT=$(sed -n 's/^(named text type #\(.*\))$/\1/p' store/names.jqd)
  $ WORLD=$(sed -n 's/^(named world effect #\(.*\))$/\1/p' store/names.jqd)
  $ SEND=$(sed -n 's/^(named send op #\(.*\))$/\1/p' store/names.jqd)
  $ DOUBLE=$(sed -n 's/^(named double term #\(.*\))$/\1/p' store/names.jqd)
  $ ECHO=$(sed -n 's/^(named echo term #\(.*\))$/\1/p' store/names.jqd)
  $ names() { sed "s/$INT/<int>/g; s/$TEXT/<text>/g; s/$WORLD/<world>/g; s/$SEND/<send>/g; s/$DOUBLE/<double>/g; s/$ECHO/<echo>/g"; }
  $ LIMITS='{"max_arguments":64,"max_collection_items":1024,"max_diagnostic_bytes":65536,"max_diagnostics":32,"max_effect_requests":1024,"max_effects":64,"max_frame_bytes":1048576,"max_host_message_bytes":4096,"max_json_depth":64,"max_operations":256,"max_stderr_bytes":65536,"max_text_bytes":262144,"max_value_nodes":4096}'
  $ SELECT="{\"kind\":\"host_select\",\"limits\":$LIMITS,\"protocol\":\"jacquard-host-v0\"}"
  $ INT_TYPE="{\"arguments\":[],\"identity\":\"$INT\",\"kind\":\"nominal\"}"
  $ TEXT_TYPE="{\"arguments\":[],\"identity\":\"$TEXT\",\"kind\":\"nominal\"}"
  $ INVOKE_DOUBLE="{\"arguments\":[{\"kind\":\"int\",\"value\":\"21\"}],\"capabilities\":{\"effects\":[],\"operations\":[]},\"interface\":{\"effects\":[],\"parameters\":[$INT_TYPE],\"result\":$INT_TYPE},\"invocation_id\":\"0000000000000000\",\"kind\":\"invoke\",\"protocol\":\"jacquard-host-v0\",\"target\":{\"callable\":\"$DOUBLE\",\"kind\":\"store-term-v0\"}}"
  $ INVOKE_ECHO="{\"arguments\":[{\"kind\":\"text\",\"value\":\"ping\"}],\"capabilities\":{\"effects\":[\"$WORLD\"],\"operations\":[{\"effect\":\"$WORLD\",\"mode\":\"once\",\"operation\":\"$SEND\"}]},\"interface\":{\"effects\":[\"$WORLD\"],\"parameters\":[$TEXT_TYPE],\"result\":$TEXT_TYPE},\"invocation_id\":\"0000000000000000\",\"kind\":\"invoke\",\"protocol\":\"jacquard-host-v0\",\"target\":{\"callable\":\"$ECHO\",\"kind\":\"store-term-v0\"}}"
  $ EFFECT_OK='{"invocation_id":"0000000000000000","kind":"effect_ok","protocol":"jacquard-host-v0","request_id":"0000000000000001","value":{"kind":"text","value":"pong"}}'

A pure invocation: core_hello, then one outcome with the typed result and
Core evidence that omits argument and result values.

  $ { frame "$SELECT"; frame "$INVOKE_DOUBLE"; } > pure.in
  $ jacquard host worker --store store < pure.in > pure.out
  $ unframe < pure.out | names
  {"carrier":"stdio-u32-json-v0","kind":"core_hello","limits":{"max_arguments":64,"max_collection_items":1024,"max_diagnostic_bytes":65536,"max_diagnostics":32,"max_effect_requests":1024,"max_effects":64,"max_frame_bytes":1048576,"max_host_message_bytes":4096,"max_json_depth":64,"max_operations":256,"max_stderr_bytes":65536,"max_text_bytes":262144,"max_value_nodes":4096},"versions":["jacquard-host-v0"]}
  {"evidence":{"core":{"capabilities":{"effects":[],"operations":[]},"effect_requests":[],"interface":{"effects":[],"parameters":[{"arguments":[],"identity":"<int>","kind":"nominal"}],"result":{"arguments":[],"identity":"<int>","kind":"nominal"}},"invocation_id":"0000000000000000","schema":"jacquard-host-core-evidence-v0","target":{"callable":"<double>","kind":"store-term-v0"},"terminal":"ok"},"host_observations":{"responses":[],"schema":"jacquard-host-observations-v0"}},"invocation_id":"0000000000000000","kind":"outcome","protocol":"jacquard-host-v0","result":{"kind":"ok","value":{"kind":"int","value":"42"}}}

One configured once operation: Core emits the request, the host answers, and
the outcome records the request order and the accepted observation.

  $ { frame "$SELECT"; frame "$INVOKE_ECHO"; frame "$EFFECT_OK"; } > echo.in
  $ jacquard host worker --store store < echo.in > echo.out
  $ unframe < echo.out | names
  {"carrier":"stdio-u32-json-v0","kind":"core_hello","limits":{"max_arguments":64,"max_collection_items":1024,"max_diagnostic_bytes":65536,"max_diagnostics":32,"max_effect_requests":1024,"max_effects":64,"max_frame_bytes":1048576,"max_host_message_bytes":4096,"max_json_depth":64,"max_operations":256,"max_stderr_bytes":65536,"max_text_bytes":262144,"max_value_nodes":4096},"versions":["jacquard-host-v0"]}
  {"arguments":[{"kind":"text","value":"ping"}],"effect":"<world>","invocation_id":"0000000000000000","kind":"effect_request","mode":"once","operation":"<send>","protocol":"jacquard-host-v0","request_id":"0000000000000001"}
  {"evidence":{"core":{"capabilities":{"effects":["<world>"],"operations":[{"effect":"<world>","mode":"once","operation":"<send>"}]},"effect_requests":[{"effect":"<world>","operation":"<send>","ordinal":1}],"interface":{"effects":["<world>"],"parameters":[{"arguments":[],"identity":"<text>","kind":"nominal"}],"result":{"arguments":[],"identity":"<text>","kind":"nominal"}},"invocation_id":"0000000000000000","schema":"jacquard-host-core-evidence-v0","target":{"callable":"<echo>","kind":"store-term-v0"},"terminal":"ok"},"host_observations":{"responses":[{"category":"ok","completion":"completed","ordinal":1}],"schema":"jacquard-host-observations-v0"}},"invocation_id":"0000000000000000","kind":"outcome","protocol":"jacquard-host-v0","result":{"kind":"ok","value":{"kind":"text","value":"pong"}}}

A pre-invocation shutdown is acknowledged and the worker exits 0.

  $ { frame "$SELECT"; frame '{"kind":"shutdown","protocol":"jacquard-host-v0"}'; } > shutdown.in
  $ jacquard host worker --store store < shutdown.in > shutdown.out
  $ unframe < shutdown.out | names
  {"carrier":"stdio-u32-json-v0","kind":"core_hello","limits":{"max_arguments":64,"max_collection_items":1024,"max_diagnostic_bytes":65536,"max_diagnostics":32,"max_effect_requests":1024,"max_effects":64,"max_frame_bytes":1048576,"max_host_message_bytes":4096,"max_json_depth":64,"max_operations":256,"max_stderr_bytes":65536,"max_text_bytes":262144,"max_value_nodes":4096},"versions":["jacquard-host-v0"]}
  {"kind":"shutdown_ack","protocol":"jacquard-host-v0"}

An unsupported version is refused with one fatal frame; the flushed terminal
permits exit 0.

  $ frame '{"kind":"host_select","limits":{},"protocol":"jacquard-host-v1"}' > version.in
  $ jacquard host worker --store store < version.in > version.out
  $ unframe < version.out | names
  {"carrier":"stdio-u32-json-v0","kind":"core_hello","limits":{"max_arguments":64,"max_collection_items":1024,"max_diagnostic_bytes":65536,"max_diagnostics":32,"max_effect_requests":1024,"max_effects":64,"max_frame_bytes":1048576,"max_host_message_bytes":4096,"max_json_depth":64,"max_operations":256,"max_stderr_bytes":65536,"max_text_bytes":262144,"max_value_nodes":4096},"versions":["jacquard-host-v0"]}
  {"diagnostics":[{"schema":"jacquard-diagnostic-v1","domain":"process","code":"E1600","severity":"error","span":null,"summary":"The host selected an unsupported protocol version.","cause":"The selected protocol version is not advertised.","next_step":"Select jacquard-host-v0 with the advertised stdio-u32-json-v0 carrier."}],"kind":"fatal","protocol":"jacquard-host-v0"}

A truncated length prefix is carrier loss: Core still flushes a best-effort
E1611 fatal because stdout remains writable, notes the loss on stderr, and
exits 74.

  $ printf '\000\000' > truncated.in
  $ jacquard host worker --store store < truncated.in > truncated.out
  jacquard host worker: the carrier was lost while awaiting host_select (E1611)
  [74]
  $ unframe < truncated.out | names
  {"carrier":"stdio-u32-json-v0","kind":"core_hello","limits":{"max_arguments":64,"max_collection_items":1024,"max_diagnostic_bytes":65536,"max_diagnostics":32,"max_effect_requests":1024,"max_effects":64,"max_frame_bytes":1048576,"max_host_message_bytes":4096,"max_json_depth":64,"max_operations":256,"max_stderr_bytes":65536,"max_text_bytes":262144,"max_value_nodes":4096},"versions":["jacquard-host-v0"]}
  {"diagnostics":[{"schema":"jacquard-diagnostic-v1","domain":"process","code":"E1611","severity":"error","span":null,"summary":"The host carrier was lost before a trustworthy frame completed.","cause":"The carrier ended before the declared frame completed.","next_step":"Treat the missing terminal exchange as host-owned carrier-failure evidence."}],"kind":"fatal","protocol":"jacquard-host-v0"}

A standard output that cannot be written is carrier loss: one operator note,
no retry of the failed frame, exit 74.

  $ jacquard host worker --store store < pure.in >&-
  jacquard host worker: core_hello could not be written (E1611)
  [74]

Startup configuration failures happen before any frame is written.

  $ jacquard host worker --store nowhere
  error[E0606]: Requested store is unavailable
    Cause: store nowhere does not exist
    Next step: Pass the path to an existing Jacquard store.
  [1]
  $ jacquard host worker 2>&1 | head -2
  Usage: jacquard host worker [--help] [--diagnostic-format=FORMAT] --store=DIR
         [OPTION]…
