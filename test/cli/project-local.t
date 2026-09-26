Local projects without dependencies (PKG.1, docs/designs/project-structure.md
§4-§7, §10). The library units compose as one program and are checked once;
each entry composes separately over the frozen library.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ mkdir -p shop/src && cd shop && mkdir .git && root=$PWD
  $ cat > project.jqd <<'M'
  > (project-v1
  >   (name "shop")
  >   (requires (core "0.2"))
  >   (namespace shop)
  >   (units "src/types.jac" "src/price.jac")
  >   (entries
  >     (run demo (units "demo.jac"))
  >     (run greet (units "greet.jac") (grants console))
  >     (test suite (units "tests.jac"))))
  > M

A recursive group spans the two library units, as it would in their
concatenation; a Warp test bound by the library is not owned by any entry.

  $ cat > src/types.jac <<'S'
  > type ShopItem = | ShopItem(name: Text, price: Int)
  > shop.library-check = Case("library-owned", fn () -> check.true(True, "not an entry test"))
  > shop.even(n) = match n { | 0 -> True | _ -> shop.odd(int.sub(n, 1)) }
  > S
  $ cat > src/price.jac <<'S'
  > shop.odd(n) = match n { | 0 -> False | _ -> shop.even(int.sub(n, 1)) }
  > shop.total(items) = list.fold(items, 0, fn (sum, item) -> int.add(sum, shop-item.price(item)))
  > S
  $ cat > demo.jac <<'S'
  > shop.total([ShopItem("tea", 2), ShopItem("cake", 3)])
  > shop.even(10)
  > S
  $ cat > greet.jac <<'S'
  > println("hello")
  > S
  $ cat > tests.jac <<'S'
  > shop.tests = Group("shop", [Case("total", fn () -> check.eq(shop.total([ShopItem("a", 2)]), 2, int.eq, int.show, "sum"))])
  > S
  $ jacquard project check
  $TESTCASE_ROOT/shop/project.jqd: project-v1 manifest valid (2 units, 0 exports, 0 deps, 3 entries)
  library: 6 declarations checked
  entry demo (run): checked; requires nothing
  entry greet (run): checked; requires console
  entry suite (test): checked, 1 tests; requires nothing
  $ jacquard project run demo
  5
  true
  $ jacquard project run greet --allow console
  hello
  ()
  $ jacquard project test --seed 1 --no-cache
  entry suite
  PASS shop.tests/shop/total (1 check)
  1 passed, 0 failed, 0 skipped, 0 refused

The result is the same from a subdirectory, a parent, or an unrelated
directory, and nothing is written outside the chosen roots:

  $ (cd src && jacquard project run demo)
  5
  true
  $ (cd .. && jacquard project run demo --project shop)
  5
  true
  $ (cd /tmp && jacquard project run demo --project "$root")
  5
  true
  $ find . -newer project.jqd -not -path './.git*' | sort
  .
  ./demo.jac
  ./greet.jac
  ./src
  ./src/price.jac
  ./src/types.jac
  ./tests.jac

Entries are named, and a run entry is not a test entry:

  $ jacquard project run nope 2>&1 | head -2
  error[E1718]: The project declares no entry of that name and kind.
    Cause: $TESTCASE_ROOT/shop/project.jqd has no entry `nope`; it declares `demo`, `greet`, `suite`
  $ jacquard project test demo 2>&1 | head -2
  error[E1718]: The project declares no entry of that name and kind.
    Cause: `demo` is a run entry, not a test entry; use jacquard project run demo

Declared grants are compared with checked authority; a manifest never grants:

  $ jacquard project run greet 2>&1 | grep -o 'error\[E0814\]'
  error[E0814]
  $ sed -i 's/(grants console)/(grants console net)/; s/(run demo (units "demo.jac"))/(run demo (units "demo.jac") (grants fs))/' project.jqd
  $ jacquard project check 2>&1 | grep -A1 'W1700'
  warning[W1700]: An entry's declared grants differ from its checked authority.
    Cause: entry `demo` declares `fs` but its checked code never requires it
  --
  warning[W1700]: An entry's declared grants differ from its checked authority.
    Cause: entry `greet` declares `net` but its checked code never requires it
  $ jacquard project check --strict-grants > /dev/null 2>&1; echo "exit $?"
  exit 1
  $ jacquard project check --strict-grants 2>&1 | grep -o 'error\[E1730\]' | sort -u
  error[E1730]
  $ sed -i 's/ (grants fs)//; s/(grants console net)//' project.jqd
  $ jacquard project check 2>&1 | grep -A1 'W1700'
  warning[W1700]: An entry's declared grants differ from its checked authority.
    Cause: entry `greet` requires `console` but its (grants ...) does not declare it
  $ sed -i 's/(units "greet.jac")/(units "greet.jac") (grants console)/' project.jqd

The library holds declarations only, each name is defined in one unit, and
every library name carries the namespace; constructors are owned by their
types and exempt:

  $ cp src/price.jac price.bak
  $ echo 'shop.total([])' >> src/price.jac
  $ jacquard project check 2>&1 | grep -A1 'E1715'
  $TESTCASE_ROOT/shop/src/price.jac:3:1-15: error[E1715]: A declarations-only unit contains a top-level expression.
    Cause: a library unit holds declarations only; found a top-level expression
  $ cp price.bak src/price.jac && echo 'shop.even(n) = True' >> src/price.jac
  $ jacquard project check 2>&1 | grep -A1 'E1716'
  $TESTCASE_ROOT/shop/src/price.jac:3:1-20: error[E1716]: A name is defined in two units.
    Cause: `shop.even` is defined in $TESTCASE_ROOT/shop/src/types.jac and again in $TESTCASE_ROOT/shop/src/price.jac
  $ cp price.bak src/price.jac && echo 'type ShopItem = | Other' >> src/price.jac
  $ jacquard project check 2>&1 | grep -A1 'E1716'
  $TESTCASE_ROOT/shop/src/price.jac:3:1-24: error[E1716]: A name is defined in two units.
    Cause: type `shop-item` is defined in $TESTCASE_ROOT/shop/src/types.jac and again in $TESTCASE_ROOT/shop/src/price.jac
  $ cp price.bak src/price.jac && printf 'helper(x) = x\ntype Basket = | Basket(size: Int)\n' >> src/price.jac
  $ jacquard project check 2>&1 | grep -A1 'E1706'
  $TESTCASE_ROOT/shop/src/price.jac:3:1-14: error[E1706]: A library name does not carry the project's namespace.
    Cause: term `helper` ($TESTCASE_ROOT/shop/src/price.jac) does not begin with `shop.`, as namespace `shop` requires
  --
  $TESTCASE_ROOT/shop/src/price.jac:4:1-34: error[E1706]: A library name does not carry the project's namespace.
    Cause: type `basket` ($TESTCASE_ROOT/shop/src/price.jac) does not begin with `shop-`, as namespace `shop` requires
  --
  $TESTCASE_ROOT/shop/src/price.jac:4:24-33: error[E1706]: A library name does not carry the project's namespace.
    Cause: term `basket.size` ($TESTCASE_ROOT/shop/src/price.jac) does not begin with `shop.`, as namespace `shop` requires
  $ cp price.bak src/price.jac && echo 'type ShopMaybe = | Some(value: Int) | Nothing' >> src/price.jac
  $ jacquard project check 2>&1 | grep -A1 'E1731'
  $TESTCASE_ROOT/shop/src/price.jac:3:20-36: error[E1731]: Two visible constructors share a name.
    Cause: constructor `some` of type `shop-maybe` is also a constructor of type `option` of the prelude

The library is checked before, and without, any entry:

  $ cp price.bak src/price.jac && echo 'shop.greeting() = shop.banner()' >> src/price.jac
  $ echo 'shop.banner() = "hi"' >> demo.jac
  $ jacquard project check 2>&1 | grep -A1 'E1732'
  $TESTCASE_ROOT/shop/src/price.jac:3:19-30: error[E1732]: The library refers to a name that only an entry defines.
    Cause: the library refers to `shop.banner`, which only entry `demo` defines; entries are composed after the library and cannot be referenced by it
  $ cp price.bak src/price.jac && sed -i '$d' demo.jac

Unit paths stay inside the project, name regular files, and are listed once:

  $ mkdir ../outside && echo 'shop.far = 1' > ../outside/far.jac && ln -s ../outside/far.jac far.jac
  $ sed -i 's|"src/price.jac")|"src/price.jac" "far.jac" "../outside/far.jac" "missing.jac" "src/Types.jac" "./src/types.jac")|' project.jqd
  $ mkdir missing.jac && cp src/types.jac src/Types.jac
  $ jacquard project check 2>&1 | grep -A1 '^error'
  error[E1722]: A unit path leaves the project directory.
    Cause: unit "far.jac" resolves to $TESTCASE_ROOT/outside/far.jac, outside the project directory $TESTCASE_ROOT/shop
  --
  error[E1722]: A unit path leaves the project directory.
    Cause: unit "../outside/far.jac" resolves to $TESTCASE_ROOT/outside/far.jac, outside the project directory $TESTCASE_ROOT/shop
  --
  error[E1723]: A unit is missing or is not a regular file.
    Cause: unit "missing.jac" is not a regular file
  --
  error[E1724]: Two units' paths differ only by letter case.
    Cause: the library lists "src/types.jac" and "src/Types.jac", which differ only by letter case
  --
  error[E1734]: Two unit entries name the same file.
    Cause: the library lists "src/types.jac" and "./src/types.jac", which are the same file $TESTCASE_ROOT/shop/src/types.jac

A unit's bytes are bounded before parsing:

  $ cp project.jqd broken.jqd && sed -i 's|"src/price.jac" .*"./src/types.jac")|"src/price.jac" "big.jac")|' project.jqd
  $ head -c 4194305 /dev/zero | tr '\0' ' ' > big.jac
  $ jacquard project check 2>&1 | grep -A1 '^error'
  error[E1703]: A project input exceeds a size budget.
    Cause: unit "big.jac" exceeds the unit limit of 4194304 bytes
