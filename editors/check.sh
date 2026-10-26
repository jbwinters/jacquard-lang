#!/bin/sh
# Check that the editor grammars reserve exactly the keywords the surface
# lexer reserves (Surface_lex.keywords in src/surface_lex.ml). The contextual
# `opaque` (before `type`) is highlighted too but is not a lexer keyword.
# Usage: sh editors/check.sh   (from any directory)
# Needs python3 to read the TextMate JSON. It compares the TextMate rules in
# repository.keyword and every Vim `syn[tax] keyword` statement; keywords
# highlighted some other way are not compared.
set -eu
export LC_ALL=C

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# One keyword per line, as `ocamlformat` lays the list out.
sed -n '/^let keywords =/,/]/p' "$root/src/surface_lex.ml" |
  sed -n 's/^[[:space:]]*"\([a-z]*\)";\{0,1\}[[:space:]]*$/\1/p' | sort >"$tmp/lexer"
[ -s "$tmp/lexer" ] || { echo "could not read Surface_lex.keywords" >&2; exit 2; }

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

sed -n 's/^[[:space:]]*syn\(tax\)\{0,1\}[[:space:]]\{1,\}keyword[[:space:]]\{1,\}\(jacquard[A-Za-z]*\)[[:space:]]\{1,\}//p' \
  "$root/editors/vim/syntax/jacquard.vim" | grep -v '\<contained\>' |
  tr -s ' \t' '\n\n' | sed '/^$/d' | sort >"$tmp/vim"

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
