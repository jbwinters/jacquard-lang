/* Task-equivalent twin of bench/mutate.jqd — C has no code values; the
 * counterpart runs the same single-edit mutant algorithm over the same
 * tree as tagged structs. Mutant spines are fresh allocations sharing
 * unchanged children by pointer, as the RC-shared forms do; each of the
 * 300 rounds allocates from a bump arena and resets it, the moral
 * equivalent of the pool the Jacquard runtime recycles per drop. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct form form;
typedef struct arg {
  int kind; /* 0 form, 1 int, 2 sym */
  union {
    const form *f;
    long i;
    const char *s;
  } u;
} arg;
struct form {
  const char *head;
  int n;
  arg a[3];
};

static char arena[1 << 20];
static size_t arena_top;
static void *amalloc(size_t n) {
  n = (n + 15) & ~(size_t)15;
  if (arena_top + n > sizeof arena) {
    fputs("arena overflow\n", stderr);
    exit(1);
  }
  void *p = arena + arena_top;
  arena_top += n;
  return p;
}

static arg af(const form *f) { return (arg){ 0, { .f = f } }; }
static arg ai(long i) { return (arg){ 1, { .i = i } }; }
static arg as(const char *s) { return (arg){ 2, { .s = s } }; }

static const form V_N = { "var", 1, { { 2, { .s = "n" } } } };
static const form V_ADD = { "var", 1, { { 2, { .s = "add" } } } };
static const form V_SUB = { "var", 1, { { 2, { .s = "sub" } } } };
static const form V_MUL = { "var", 1, { { 2, { .s = "mul" } } } };
static const form V_DIV = { "var", 1, { { 2, { .s = "div" } } } };
static const form *OP_SWAPS[3] = { &V_ADD, &V_SUB, &V_MUL };

static form *node(const char *head, int n, arg a0, arg a1, arg a2) {
  form *f = amalloc(sizeof(form));
  f->head = head;
  f->n = n;
  f->a[0] = a0;
  f->a[1] = a1;
  f->a[2] = a2;
  return f;
}

static int form_eq(const form *x, const form *y) {
  if (strcmp(x->head, y->head) != 0 || x->n != y->n) return 0;
  for (int i = 0; i < x->n; i++) {
    if (x->a[i].kind != y->a[i].kind) return 0;
    switch (x->a[i].kind) {
    case 0:
      if (!form_eq(x->a[i].u.f, y->a[i].u.f)) return 0;
      break;
    case 1:
      if (x->a[i].u.i != y->a[i].u.i) return 0;
      break;
    default:
      if (strcmp(x->a[i].u.s, y->a[i].u.s) != 0) return 0;
    }
  }
  return 1;
}

/* the mutants of [c]; each result is a fresh spine sharing unchanged
 * children. Returns the count; trees land in [out] up to [cap]. */
static int code_mutants(const form *c, const form **out, int cap) {
  int n = 0;
  for (int k = 0; k < 3; k++)
    if (form_eq(c, OP_SWAPS[k])) {
      for (int j = 0; j < 3; j++)
        if (j != k && n < cap) out[n++] = OP_SWAPS[j];
    }
  if (strcmp(c->head, "lit") == 0 && c->n == 1 && c->a[0].kind == 1) {
    if (n < cap) out[n++] = node("lit", 1, ai(c->a[0].u.i - 1), ai(0), ai(0));
    if (n < cap) out[n++] = node("lit", 1, ai(c->a[0].u.i + 1), ai(0), ai(0));
  }
  int all_forms = 1;
  for (int i = 0; i < c->n; i++)
    if (c->a[i].kind != 0) all_forms = 0;
  if (!all_forms) return n;
  for (int i = 0; i < c->n; i++) {
    const form *sub[64];
    int m = code_mutants(c->a[i].u.f, sub, 64);
    for (int j = 0; j < m && n < cap; j++) {
      form *r = amalloc(sizeof(form));
      *r = *c;
      r->a[i] = af(sub[j]);
      out[n++] = r;
    }
  }
  return n;
}

int main(void) {
  long total = 0;
  for (int round = 0; round < 300; round++) {
    arena_top = 0;
    /* the subject, rebuilt per round like the const member is read per
     * fold iteration */
    const form *lit1 = node("lit", 1, ai(1), ai(0), ai(0));
    const form *lit2 = node("lit", 1, ai(2), ai(0), ai(0));
    const form *lit3 = node("lit", 1, ai(3), ai(0), ai(0));
    const form *lit4 = node("lit", 1, ai(4), ai(0), ai(0));
    const form *pn = node("pvar", 1, as("n"), ai(0), ai(0));
    const form *params = node("group", 1, af(pn), ai(0), ai(0));
    const form *sub1 = node("app", 3, af(&V_SUB), af(&V_N), af(lit1));
    const form *mul1 = node("app", 3, af(&V_MUL), af(&V_N), af(sub1));
    const form *div1 = node("app", 3, af(&V_DIV), af(mul1), af(lit2));
    const form *add2 = node("app", 3, af(&V_ADD), af(&V_N), af(lit4));
    const form *mul2 = node("app", 3, af(&V_MUL), af(lit3), af(add2));
    const form *body = node("app", 3, af(&V_ADD), af(div1), af(mul2));
    const form *subject = node("lam", 2, af(params), af(body), ai(0));
    const form *out[64];
    total += code_mutants(subject, out, 64);
  }
  printf("%ld\n", total);
  return 0;
}
