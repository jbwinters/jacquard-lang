/* hand-written C reference for bench/fib.jqd (task 75): the same naive
 * recursion over 64-bit ints, printed like the jacquard driver prints. */
#include <stdint.h>
#include <stdio.h>

static int64_t fib(int64_t n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int main(void) {
  printf("%lld\n", (long long)fib(30));
  return 0;
}
