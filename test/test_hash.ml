open Jacquard

(* Known SHA-256 vectors pin HASH_V0 to its intended algorithm. *)
let test_known_vectors () =
  Alcotest.(check string)
    "sha256(\"\")" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    (Hash.to_hex (Hash.of_string ""));
  Alcotest.(check string)
    "sha256(abc)" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    (Hash.to_hex (Hash.of_string "abc"))

let test_hex_roundtrip () =
  let h = Hash.of_string "roundtrip" in
  (match Hash.of_hex (Hash.to_hex h) with
  | Some h' -> Alcotest.(check bool) "roundtrip equal" true (Hash.equal h h')
  | None -> Alcotest.fail "of_hex rejected to_hex output");
  match Hash.of_hex (String.uppercase_ascii (Hash.to_hex h)) with
  | Some h' -> Alcotest.(check bool) "uppercase accepted" true (Hash.equal h h')
  | None -> Alcotest.fail "of_hex rejected uppercase hex"

let test_of_hex_rejects () =
  Alcotest.(check bool) "short" true (Hash.of_hex "abc" = None);
  Alcotest.(check bool) "non-hex" true (Hash.of_hex (String.make (2 * Hash.digest_size) 'g') = None);
  Alcotest.(check bool) "empty" true (Hash.of_hex "" = None);
  let spelling = Hash.(to_hex (of_string "canonical")) in
  Alcotest.(check bool) "canonical lowercase accepted" true (Hash.of_canonical_hex spelling <> None);
  Alcotest.(check bool)
    "canonical boundary rejects uppercase" true
    (Hash.of_canonical_hex (String.uppercase_ascii spelling) = None);
  Alcotest.(check bool)
    "canonical boundary rejects prefix" true
    (Hash.of_canonical_hex ("#" ^ spelling) = None)

let test_equality_and_order () =
  let a = Hash.of_string "a" and b = Hash.of_string "b" in
  Alcotest.(check bool) "equal self" true (Hash.equal a a);
  Alcotest.(check bool) "distinct inputs distinct" false (Hash.equal a b);
  Alcotest.(check bool) "compare consistent" true (Hash.compare a b <> 0 && Hash.compare a a = 0)

let suite =
  [
    Alcotest.test_case "known SHA-256 vectors" `Quick test_known_vectors;
    Alcotest.test_case "hex roundtrip" `Quick test_hex_roundtrip;
    Alcotest.test_case "of_hex rejects bad input" `Quick test_of_hex_rejects;
    Alcotest.test_case "equality and ordering" `Quick test_equality_and_order;
  ]
