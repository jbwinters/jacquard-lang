ET.5 Secret root handlers are explicit grants. The environment adapter uses a
collision-free key derived from the safe SecretRef and never prints the value.

  $ export JACQUARD_PRELUDE=../../prelude
  $ cat > secret-read.jqd <<'JACQUARD'
  > (app (var secret.read)
  >   (app (var secret-ref) (lit "fixture") (var none)))
  > JACQUARD
  $ jacquard run secret-read.jqd
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires secret [governance/special] — resolve opaque confidential material or explicitly expose it, which is not granted (performed via `secret.read`).
    Next step: grant it with --allow secret, or handle the effect in the program
  [3]
  $ jacquard run secret-read.jqd --allow secret
  error: World-effect I/O failed
    Cause: io error: secret reference not found: fixture
    Next step: Correct the path, permissions, or external resource and try again.
  [2]

The exact latest key for `fixture` is JACQUARD_SECRET_V0_ plus the UTF-8 bytes
of the name in lowercase hex. A non-sensitive payload remains absent from both
stdout and stderr.

  $ payload="et5-$(printf adapter)-42"
  $ key=JACQUARD_SECRET_V0_66697874757265_LATEST
  $ env "$key=$payload" jacquard run secret-read.jqd --allow secret >secret.out 2>secret.err
  $ cat secret.out
  <secret redacted>
  $ if grep -F "$payload" secret.out secret.err >/dev/null; then echo LEAKED; else echo redacted; fi
  redacted

Versioned references use a distinct exact key and explicit exposure still
retains the Secret grant while the transcript reveals only a boolean.

  $ cat > secret-version.jqd <<'JACQUARD'
  > (app (var text.contains?)
  >   (app (var secret.expose)
  >     (app (var secret.read)
  >       (app (var secret-ref) (lit "fixture") (app (var some) (lit "v1")))))
  >   (lit "adapter"))
  > JACQUARD
  $ jacquard check secret-version.jqd --print-sigs
  _ : Bool
  $ version_key=JACQUARD_SECRET_V0_66697874757265_VERSION_7631
  $ env "$version_key=$payload" jacquard run secret-version.jqd --allow secret >version.out 2>version.err
  $ cat version.out
  true
  $ if grep -F "$payload" version.out version.err >/dev/null; then echo LEAKED; else echo redacted; fi
  redacted
  $ jacquard run secret-version.jqd --allow secret
  error: World-effect I/O failed
    Cause: io error: secret version not found: fixture@v1
    Next step: Correct the path, permissions, or external resource and try again.
  [2]

Dry-run deliberately ignores live grants and installs no Secret resolver. Even
with `--allow secret` and a populated environment, manifest checking refuses
before a lookup can occur.

  $ env "$key=$payload" jacquard run secret-read.jqd --dry-run --allow secret
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires secret [governance/special] — resolve opaque confidential material or explicitly expose it, which is not granted (performed via `secret.read`).
    Next step: grant it with --allow secret, or handle the effect in the program
  [3]
