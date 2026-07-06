/* hand-written C reference for bench/sort.jqd (task 75): the SAME merge
 * sort over heap-allocated cons nodes — the claim compares the language's
 * list discipline against C practicing the same discipline, not against a
 * flat-array qsort (which measures the representation, not the compiler). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct node {
  int64_t v;
  struct node *next;
} node;

static node *cons(int64_t v, node *next) {
  node *n = malloc(sizeof(node));
  n->v = v;
  n->next = next;
  return n;
}

/* split into alternating halves, sort each, merge — list.sort's shape */
static node *merge(node *a, node *b) {
  node head = { 0, NULL };
  node *t = &head;
  while (a && b) {
    if (a->v <= b->v) { t->next = a; a = a->next; }
    else { t->next = b; b = b->next; }
    t = t->next;
  }
  t->next = a ? a : b;
  return head.next;
}

static node *msort(node *xs) {
  if (!xs || !xs->next) return xs;
  node *a = NULL, *b = NULL;
  while (xs) {
    node *n = xs->next;
    xs->next = a; a = xs;
    xs = n;
    if (xs) { n = xs->next; xs->next = b; b = xs; xs = n; }
  }
  return merge(msort(a), msort(b));
}

int main(void) {
  node *xs = NULL;
  /* list.range is half-open: exactly 200000 nodes, like the .jqd program */
  for (int64_t i = 0; i < 200000; i++) xs = cons(i, xs);
  xs = msort(xs);
  int64_t len = 0;
  for (node *p = xs; p; p = p->next) len++;
  printf("%lld\n", (long long)len);
  return 0;
}
