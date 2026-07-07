/* Task-equivalent twin of bench/state-loop.jqd — C has no effect
 * handlers, so this prices the abstraction: the same million get/put
 * pairs as calls to opaque accessor functions on a state cell. noinline
 * keeps one real call per operation; without it the compiler folds the
 * whole loop to a constant and the row measures nothing. */
#include <stdint.h>
#include <stdio.h>

static int64_t cell;
__attribute__((noinline)) static int64_t get(void) { return cell; }
__attribute__((noinline)) static void put(int64_t v) { cell = v; }

int main(void) {
  cell = 0;
  for (int64_t n = 1000000; n >= 1; n--) put(get() + 1);
  printf("%lld\n", (long long)get());
  return 0;
}
