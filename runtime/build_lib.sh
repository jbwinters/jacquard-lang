#!/bin/sh
# Builds libjqrt.a (consumed by `jacquard build`, task 67). Dune invokes this
# from the sandbox copy of runtime/.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CC=${CC:-cc}
for f in jq_alloc jq_rc jq_text jq_error jq_show jq_utf8 jq_rng; do
  $CC -std=c11 -O2 -Wall -Wextra -Werror -c "$here/$f.c" -o "$here/$f.o"
done
ar rcs "$here/libjqrt.a" "$here"/jq_alloc.o "$here"/jq_rc.o "$here"/jq_text.o "$here"/jq_error.o "$here"/jq_show.o "$here"/jq_utf8.o "$here"/jq_rng.o
