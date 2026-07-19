SS.22 standard-library names and variadic text building are source-level
features shared by bootstrap and surface programs. Native v1 parity is pinned
through its global eight-argument application ceiling.

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang

The tracked bootstrap smoke covers zero/one/many joins, direct text equality,
integer boundaries, all numeric predicates, real arithmetic, and IEEE NaN
comparisons.

  $ jacquard run ../native-gauntlet/g35-stdlib-ss22.jqd > interpreter.out 2>&1
  $ jacquard build ../native-gauntlet/g35-stdlib-ss22.jqd -o ss22-native > /dev/null
  $ ./ss22-native > native.out 2>&1
  $ diff interpreter.out native.out && echo identical
  identical
  $ cat native.out
  ""
  "one"
  "ab"
  "hé👍"
  ("", "one", "abc", "abcdefgh")
  true
  false
  (true, true, true, true)
  (3.0, -1.0, 6.0, 0.5)
  (false, true, false, true)
  (true, true, false, false)
  (false, false, false, false)

The surface twin resolves the same dotted names and variadic calls.

  $ jacquard run ../../corpus/valid/stdlib-ss22.jac
  ("", "one", "ab", true, true, true, true, true, true, true, true)

Static diagnostics reject the first non-Text argument on both source routes.

  $ cat > bad.jac <<'EOF'
  > text.join("ok", 1, "unreached")
  > EOF
  $ jacquard run bad.jac 2>&1 | sed 's/bad.jac:[0-9]*:[0-9]*-[0-9]*/bad.jac:LINE:SPAN/'
  bad.jac:LINE:SPAN: error[E0801]: Types do not agree
    Cause: variadic argument: expected text, got int (type mismatch)
    Next step: the expected side comes from the surrounding context; make both sides agree
  $ cat > bad.jqd <<'EOF'
  > (app (var text.join) (lit "ok") (lit 1) (lit "unreached"))
  > EOF
  $ jacquard build bad.jqd -o bad-native 2>&1 | sed 's/bad.jqd:[0-9]*:[0-9]*-[0-9]*/bad.jqd:LINE:SPAN/'
  bad.jqd:LINE:SPAN: error[E0801]: Types do not agree
    Cause: variadic argument: expected text, got int (type mismatch)
    Next step: the expected side comes from the surrounding context; make both sides agree

The D39 public rename preserves the five pre-SS.22 semantic identities. Direct
hash references typecheck and execute in both engines even though the old names
are absent from the public index.

  $ cat > real-hash-refs.jqd <<'EOF'
  > (app (ref #d2c5dfae79852c3b7c2d8426df692b04fb8549fd4b400a3ee3c2be5f04a0f76e term) (lit 5.0) (lit 2.0))
  > (app (ref #eba25d96c355d541e1beab4c94bf2b2c4e0d39118e937024b6093a2d89295978 term) (lit 5.0) (lit 2.0))
  > (app (ref #da578d1fb2e56f6670c2cfd6dff60e73c190e66895e30b7152d84713cd1e34bb term) (lit 5.0) (lit 2.0))
  > (app (ref #f31ba01c161dfff1da955403edc8ff03e7d23b92df9d8dd50a5e9bd82b4a0678 term) (lit 5.0) (lit 2.0))
  > (app (ref #01a2e8cf101a6e0ae1f64a6df1f12a19c8ba98b674407d5125721133f9b112fb term) (lit 2.0) (lit 5.0))
  > EOF
  $ jacquard run real-hash-refs.jqd > hash-interpreter.out 2>&1
  $ jacquard build real-hash-refs.jqd -o real-hash-refs-native > /dev/null
  $ ./real-hash-refs-native > hash-native.out 2>&1
  $ diff hash-interpreter.out hash-native.out && echo identical
  identical
  $ cat hash-native.out
  7.0
  3.0
  10.0
  2.5
  true

The pre-SS.22 list-plus-separator object remains available only as the
deprecated migration binding `text.join-list`. Its old hash has its old type
and semantics in the checker, interpreter, and native compiler.

  $ cat > old-join-hash.jqd <<'EOF'
  > (var text.join-list)
  > (app (ref #b39cc4607d94b6fc777f781207fff5d9bf9dff9d96ff11361a69d4032a0a4bfd term)
  >   (app (var cons) (lit "a") (app (var cons) (lit "b") (var nil))) (lit "-"))
  > EOF
  $ jacquard check old-join-hash.jqd --print-sigs
  _ : (List Text, Text) ->{} Text
  _ : Text
  $ jacquard run old-join-hash.jqd > old-join-interpreter.out
  $ jacquard build old-join-hash.jqd -o old-join-native > /dev/null
  $ ./old-join-native > old-join-native.out
  $ diff old-join-interpreter.out old-join-native.out && cat old-join-native.out
  <builtin text.join>
  "a-b"

Native v1 accepts at most eight application arguments. Direct and first-class
eight-argument joins match the interpreter, including strict left-to-right
evaluation; the interpreter continues to accept nine and more arguments.

  $ cat > join-eight.jqd <<'EOF'
  > (defterm ((binding tap ()
  >   (lam ((pvar label) (pvar value))
  >     (let nonrec (pwild) (app (var print) (var label)) (var value))))))
  > (app (var text.join)
  >   (app (var tap) (lit "1") (lit "a")) (app (var tap) (lit "2") (lit "b"))
  >   (app (var tap) (lit "3") (lit "c")) (app (var tap) (lit "4") (lit "d"))
  >   (app (var tap) (lit "5") (lit "e")) (app (var tap) (lit "6") (lit "f"))
  >   (app (var tap) (lit "7") (lit "g")) (app (var tap) (lit "8") (lit "h")))
  > (let nonrec (pvar join) (var text.join)
  >   (app (var join) (lit "a") (lit "b") (lit "c") (lit "d")
  >     (lit "e") (lit "f") (lit "g") (lit "h")))
  > EOF
  $ jacquard run join-eight.jqd --allow console > join-eight-interpreter.out 2>&1
  $ jacquard build join-eight.jqd -o join-eight-native > /dev/null
  $ ./join-eight-native --allow console > join-eight-native.out 2>&1
  $ diff join-eight-interpreter.out join-eight-native.out && echo identical
  identical
  $ cat join-eight-native.out
  12345678"abcdefgh"
  "abcdefgh"

  $ cat > join-nine.jqd <<'EOF'
  > (app (var text.join) (lit "1") (lit "2") (lit "3") (lit "4") (lit "5")
  >   (lit "6") (lit "7") (lit "8") (lit "9"))
  > EOF
  $ jacquard run join-nine.jqd
  "123456789"
  $ jacquard build join-nine.jqd -o join-nine-native 2>&1
  error[E1101]: Program is outside the native v1 compilation subset
    Cause: Not yet compilable in native v1: top-level expression 0 applies more than 8 arguments (native v1 arity cap)
    Next step: Run the program with the interpreter or rewrite the unsupported construct.
  [1]

Large allocated text is byte-identical across engines without embedding its
output in the transcript.

  $ awk 'BEGIN { printf "(app (var text.join) (lit \""; for (i=0; i<65536; i++) printf "x"; printf "\") (lit \""; for (i=0; i<65536; i++) printf "y"; print "\"))" }' > join-large.jqd
  $ jacquard run join-large.jqd > join-large-interpreter.out
  $ jacquard build join-large.jqd -o join-large-native > /dev/null
  $ ./join-large-native > join-large-native.out
  $ diff join-large-interpreter.out join-large-native.out && wc -c < join-large-native.out | tr -d ' '
  131075

The runtime-erasure gauntlet reaches a non-Text eighth argument and pins the
same indexed error and exit in the interpreter and native backend.

  $ jacquard run ../native-gauntlet/e07-erasure-text-join.jqd > bad-eight-interpreter.out 2>&1; echo "exit $?"
  exit 2
  $ jacquard build ../native-gauntlet/e07-erasure-text-join.jqd -o bad-eight-native > /dev/null
  $ ./bad-eight-native > bad-eight-native.out 2>&1; echo "exit $?"
  exit 2
  $ diff bad-eight-interpreter.out bad-eight-native.out && echo identical
  identical
  $ cat bad-eight-native.out
  error: Runtime value has the wrong type
    Cause: type error: text.join expects Text at argument 8, got 5
    Next step: Pass a value of the type required by this operation.

Fatal variadic validation owns every evaluated argument. ASAN and LeakSanitizer
pin early, middle, and last bad positions plus the first-class jq_apply route;
all cases use allocated text on both sides of the bad value.

  $ export JACQUARD_NATIVE_CFLAGS="-fsanitize=address -O1 -g"
  $ for f in ../../test/native-asan/join-bad-*.jqd; do
  >   n=$(basename "$f" .jqd)
  >   jacquard build "$f" -o "asan-$n" > /dev/null
  >   ASAN_OPTIONS=detect_leaks=1 "./asan-$n" > "asan-$n.out" 2>&1; status=$?
  >   if [ "$status" = 2 ] && ! grep -q Sanitizer "asan-$n.out"; then
  >     echo "asan-clean: $n"
  >   else
  >     echo "ASAN-FAIL: $n exit=$status"; sed -n '1,20p' "asan-$n.out"
  >   fi
  > done
  asan-clean: join-bad-early
  asan-clean: join-bad-first-class
  asan-clean: join-bad-last
  asan-clean: join-bad-middle
