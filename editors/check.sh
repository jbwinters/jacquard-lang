#!/bin/sh
# Check that the editor grammars reserve exactly the keywords the surface
# lexer reserves (Surface_lex.keywords in src/surface_lex.ml). The contextual
# `opaque` (before `type`) is highlighted too but is not a lexer keyword.
# Usage: sh editors/check.sh   (from the repository root)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sed -n '/^let keywords =/,/]/p' "$root/src/surface_lex.ml" |
  grep -o '"[a-z]*"' | tr -d '"' | sort >"$tmp/lexer"

python3 - "$root/editors/textmate/jacquard.tmLanguage.json" >"$tmp/textmate" <<'PY'
import json, re, sys
grammar = json.load(open(sys.argv[1]))
words = set()
for rule in grammar["repository"]["keyword"]["patterns"]:
    alternation = re.search(r"\)\(([a-z|]+)", rule["match"]).group(1)
    words.update(alternation.split("|"))
words.discard("opaque")
print("\n".join(sorted(words)))
PY

grep '^syn keyword jacquard[A-Za-z]* ' "$root/editors/vim/syntax/jacquard.vim" |
  grep -v 'jacquardTodo' | cut -d' ' -f4- | tr ' ' '\n' | sort >"$tmp/vim"

status=0
for grammar in textmate vim; do
  if ! diff -u "$tmp/lexer" "$tmp/$grammar" >"$tmp/$grammar.diff"; then
    echo "editors/$grammar keywords differ from Surface_lex.keywords (- lexer, + grammar):"
    sed '1,2d' "$tmp/$grammar.diff"
    status=1
  fi
done

[ "$status" -eq 0 ] && echo "editor grammars match the $(wc -l <"$tmp/lexer" | tr -d ' ') lexer keywords"
exit "$status"
