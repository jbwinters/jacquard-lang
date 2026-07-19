The default text renderer preserves the five-part reading order. A span, when present, anchors the
header; the plain summary, technical cause, and exactly one primary next step follow. Contrast is
omitted unless there is one specific nearby confusion.

  $ export JACQUARD_PRELUDE=../../prelude
  $ cat > parser.jqd <<'EOF'
  > (lit 1
  > EOF
  $ jacquard run parser.jqd
  parser.jqd:1:1-2:1: error[E0106]: The source ended before the form was complete.
    Cause: unclosed form: expected `)`
    Next step: Complete the open form and its closing parenthesis.
  [1]

The opt-in json-v1 renderer is JSON Lines: one complete, versioned object per diagnostic, in the
same emission order and on stderr. Optional fields are null when structurally present and absent
when they do not apply.

  $ jacquard run parser.jqd --diagnostic-format=json-v1 2> parser.json; echo "exit:$?"
  exit:1
  $ python3 - parser.json <<'PY'
  > import json, sys
  > lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
  > item = json.loads(lines[0])
  > print(len(lines), item["schema"], item["domain"], item["code"], item["severity"])
  > print(item["span"]["start"], item["summary"])
  > print(item["cause"])
  > print(item["next_step"])
  > print("contrast" in item)
  > PY
  1 jacquard-diagnostic-v1 reader E0106 error
  {'line': 1, 'column': 1, 'offset': 0} The source ended before the form was complete.
  unclosed form: expected `)`
  Complete the open form and its closing parenthesis.
  False

Resolution uses a typed contrast only for a concrete mistaken/intended distinction.

  $ cat > contrast.jqd <<'EOF'
  > (ann (lit 1) (tref add))
  > EOF
  $ jacquard check contrast.jqd --diagnostic-format=json-v1 2> contrast.json; echo "exit:$?"
  exit:1
  $ python3 - contrast.json <<'PY'
  > import json, sys
  > item = json.load(open(sys.argv[1], encoding="utf-8"))
  > print(item["code"], item["contrast"])
  > PY
  E0302 {'mistaken': 'a term', 'intended': 'a type'}

Capability refusal keeps its established exit 3 while using the same schema and one next step.

  $ cat > capability.jqd <<'EOF'
  > (app (var print) (lit "hello"))
  > EOF
  $ jacquard run capability.jqd --diagnostic-format=json-v1 2> capability.json; echo "exit:$?"
  exit:3
  $ python3 - capability.json <<'PY'
  > import json, sys
  > item = json.load(open(sys.argv[1], encoding="utf-8"))
  > print(item["domain"], item["code"], item["span"], item["next_step"])
  > PY
  checker E0814 None grant it with --allow console, or handle the effect in the program

Historically code-less runtime failures remain code-less rather than receiving an invented stable
identity. Their exit remains 2.

  $ cat > runtime.jqd <<'EOF'
  > (app (var div) (lit 1) (lit 0))
  > EOF
  $ jacquard run runtime.jqd --diagnostic-format=json-v1 2> runtime.json; echo "exit:$?"
  exit:2
  $ python3 - runtime.json <<'PY'
  > import json, sys
  > item = json.load(open(sys.argv[1], encoding="utf-8"))
  > print(item["domain"], item["code"], item["summary"], item["cause"])
  > PY
  runtime None Arithmetic operation failed arithmetic error: division by zero

Governance failures use their own domain even when they share the same renderer and exit channel.

  $ jacquard governance reconcile governance-reconciliation-gap-v1.jqd --diagnostic-format=json-v1 2> governance.json >/dev/null; echo "exit:$?"
  exit:1
  $ python3 - governance.json <<'PY'
  > import json, sys
  > item = json.load(open(sys.argv[1], encoding="utf-8"))
  > print(item["domain"], item["code"], item["severity"], item["span"])
  > print(item["next_step"])
  > PY
  governance E1516 error None
  Reconcile the remaining action evidence before retrying or rolling back.

Recovery diagnostics remain ordered JSON Lines rather than being collapsed into one object or a
single prose message.

  $ cat > recovery.jac <<'EOF'
  > let x = ;
  > let y = ;
  > EOF
  $ jacquard check recovery.jac --diagnostic-format=json-v1 2> recovery.json; echo "exit:$?"
  exit:1
  $ python3 - recovery.json <<'PY'
  > import json, sys
  > items = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
  > print(len(items), [item["code"] for item in items])
  > print([(item["span"]["start"]["line"], item["span"]["start"]["column"]) for item in items])
  > print(all(item["next_step"] and "contrast" not in item for item in items))
  > PY
  4 ['E1220', 'E1220', 'E1220', 'E1220']
  [(1, 1), (1, 5), (2, 1), (2, 5)]
  True

Arbitrary source bytes cannot break the JSON Lines encoding. Each malformed UTF-8 byte in a
string field is rendered as U+FFFD, and the complete diagnostic remains strict UTF-8 JSON.

  $ printf '\377\n' > invalid-utf8.jac
  $ jacquard check invalid-utf8.jac --diagnostic-format=json-v1 2> invalid-utf8.json; echo "exit:$?"
  exit:1
  $ python3 - invalid-utf8.json <<'PY'
  > import json, sys
  > text = open(sys.argv[1], "rb").read().decode("utf-8")
  > items = [json.loads(line) for line in text.splitlines()]
  > print([(item["code"], item["cause"].encode("unicode_escape").decode("ascii")) for item in items])
  > PY
  [('E1210', 'unexpected surface character `\\ufffd`')]
