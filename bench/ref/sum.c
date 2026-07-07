/* hand-C twin of bench/sum.jqd with the same heap discipline: build a
 * 1M-node linked list, then fold it — not a closed-form or array loop. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct node { int64_t v; struct node *next; } node;
int main(void) {
  node *xs = NULL;
  for (int64_t i = 999999; i >= 0; i--) {
    node *n = malloc(sizeof(node));
    n->v = i;
    n->next = xs;
    xs = n;
  }
  int64_t s = 0;
  for (node *p = xs; p; p = p->next) s += p->v;
  printf("%lld\n", (long long)s);
  return 0;
}
