/* Copyright (C) 2026 Josh Winters
 * SPDX-License-Identifier: Apache-2.0
 * Additional permission applies; see ../RUNTIME-EXCEPTION.md. */

/* The native runtime's value representation (docs/native-plan.md, task 65).
 *
 * A jq_value is a tagged 64-bit word: LSB 1 is a 63-bit integer (matching the
 * interpreter's OCaml ints, so wrap semantics agree by construction); LSB 0 is
 * a pointer to an 8-byte-aligned heap block. Blocks carry an 8-byte header
 * {rc, tag, flags, n} and n payload words (TEXT keeps its byte length in
 * payload word 0; HASH is a fixed 32 bytes).
 *
 * Memory is Perceus reference counting (Reinking, Xie, de Moura, Leijen,
 * PLDI 2021): jq_dup / jq_drop / jq_drop_reuse. rc == JQ_RC_STATIC marks
 * blocks compiled into the binary; they are immortal and dup/drop skip them.
 *
 * The cycle rule: in dynamically allocated data the only heap back-edge the
 * language can construct is a let-rec closure's reference to itself
 * (validation pins let rec to one PVar bound to a Lam; defterm groups exist
 * only at top level and compile to immortal statics). That self-slot is
 * NON-OWNING as a compile-time discipline: closure construction stores it
 * without a dup, and the free walk skips it (JQ_FLAG_SELF_SLOT plus the slot
 * index in the closure header). jq_dup/jq_drop themselves have no self-slot
 * case — a jq_value does not know where it was loaded from.
 */

#ifndef JQ_VALUE_H
#define JQ_VALUE_H

/* 64-bit platforms only: the tag scheme, block sizing, and text length
   arithmetic all assume 8-byte words and a 64-bit size_t. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

_Static_assert(sizeof(void *) == 8, "the jacquard runtime is 64-bit only");

typedef uint64_t jq_value;

/* --- tags --- */

enum jq_tag {
  JQ_TUPLE = 1,
  JQ_CON = 2,
  JQ_TEXT = 3,
  JQ_REAL = 4,
  JQ_CLOSURE = 5,
  JQ_CODE = 6,   /* a quoted form (task 73): head + tagged leaf/subform args */
  JQ_RESUME = 7, /* a captured continuation (task 71): owned frame chain */
  JQ_HASH = 8,
  JQ_CONSTRUCTOR = 9, /* first-class unapplied constructor; static-only */
  JQ_OP = 10,         /* first-class effect operation; static-only */
  JQ_BUILTIN = 11,    /* first-class primitive; static-only */
  JQ_FRAME = 12,      /* a suspended activation (task 71): code, ix, slots */
  JQ_SECRET = 13,     /* opaque bytes; generic rendering is always redacted */
};

#define JQ_RC_STATIC UINT32_MAX
/* closure: env slot self_slot is non-owning. Invariant: the flag is set iff
   the header's slot bits are nonzero (jq_closure maintains it; hand-rolled
   blocks must too, or the free walk skips nothing). */
#define JQ_FLAG_SELF_SLOT 1u
/* the block came from the small-block pool (task 80) and must go back
   through jq_block_free, never libc free. Shell-reuse paths must preserve
   this bit. */
#define JQ_FLAG_POOLED 2u
/* JQ_RESUME only: ONCE selects the affine runtime backstop; USED is shared by
 * every alias of that captured block and flips before its first re-entry. */
#define JQ_FLAG_RESUME_ONCE 4u
#define JQ_FLAG_RESUME_USED 8u

typedef struct jq_block {
  uint32_t rc;
  uint8_t tag;
  uint8_t flags;
  uint16_t n; /* payload word count (TEXT: see jq_text_len) */
  uint64_t payload[];
} jq_block;

/* --- integers (63-bit, OCaml wrap semantics by construction) --- */

static inline bool jq_is_int(jq_value v) { return (v & 1) != 0; }
static inline bool jq_is_ptr(jq_value v) { return (v & 1) == 0; }

static inline jq_value jq_int(int64_t n) {
  return ((uint64_t)n << 1) | 1; /* top bit discarded: 63-bit wrap */
}
static inline int64_t jq_int_val(jq_value v) { return (int64_t)v >> 1; }

/* Arithmetic on untagged values then re-tag: the shift-out of the tag bit is
   exactly the 63-bit wrap the interpreter gets from OCaml ints (add/sub/mul
   compute in uint64 because signed overflow is UB in C). Division is
   C99 truncation with dividend-sign remainder, which matches OCaml's / and
   mod; the one edge, min_int / -1, wraps to min_int through re-tagging and
   never touches INT64_MIN / -1 (63-bit min is -2^62, and 2^62 fits int64),
   so no UB guard is needed — the parity test pins it. jq_int_div/mod are
   undefined on a zero divisor, like C; emitted code calls the _checked
   variants, which reproduce the interpreter's exact errors (exit 2). */
static inline jq_value jq_int_add(jq_value a, jq_value b) {
  /* unsigned arithmetic: int64 overflow is UB in C, and OCaml wraps */
  return jq_int((int64_t)((uint64_t)jq_int_val(a) + (uint64_t)jq_int_val(b)));
}
static inline jq_value jq_int_sub(jq_value a, jq_value b) {
  return jq_int((int64_t)((uint64_t)jq_int_val(a) - (uint64_t)jq_int_val(b)));
}
static inline jq_value jq_int_mul(jq_value a, jq_value b) {
  return jq_int((int64_t)((uint64_t)jq_int_val(a) * (uint64_t)jq_int_val(b)));
}
static inline jq_value jq_int_div(jq_value a, jq_value b) {
  return jq_int(jq_int_val(a) / jq_int_val(b));
}
static inline jq_value jq_int_mod(jq_value a, jq_value b) {
  return jq_int(jq_int_val(a) % jq_int_val(b));
}

/* Fatal runtime error: message to stderr, exit 2 — the interpreter's
   runtime-failure contract (jq_error.c). */
void jq_runtime_error(const char *msg) __attribute__((noreturn));
jq_value jq_int_div_checked(jq_value a, jq_value b);
jq_value jq_int_mod_checked(jq_value a, jq_value b);

/* --- parity kit (task 66; jq_show.c, jq_utf8.c, jq_rng.c) --- */

char *jq_show(jq_value v); /* Value.show rendering; caller frees */
uint64_t jq_utf8_width(const uint8_t *s, uint64_t n, uint64_t i);
uint64_t jq_utf8_count(const uint8_t *s, uint64_t n); /* text.length (D9) */
int64_t jq_rng_next(int64_t *state);                  /* Infer_dist.Rng */
double jq_rng_float(int64_t *state);
int64_t jq_rng_split(int64_t *state);

/* --- blocks --- */

static inline jq_block *jq_block_of(jq_value v) { return (jq_block *)v; }
static inline jq_value jq_of_block(jq_block *b) { return (jq_value)b; }
static inline bool jq_is_static(jq_block *b) { return b->rc == JQ_RC_STATIC; }

/* the canonical unit value (): a static empty tuple, never allocated */
extern jq_block jq_unit_block;
#define JQ_UNIT (jq_of_block(&jq_unit_block))

/* --- static callable info (per-declaration constants, task 67 emits them) --- */

typedef struct jq_con_info {
  uint32_t type_id;
  uint32_t ordinal;
  uint32_t arity;
  const char *name; /* feeds <constructor f/2>, con rendering, arity errors */
} jq_con_info;

typedef struct jq_op_info {
  const uint8_t *op_hash; /* 32 bytes; may be NULL in compiled programs */
  const char *effect_name;
  const char *op_name; /* feeds <op effect.op> and perform dispatch (task 70) */
  uint32_t ordinal;    /* the link-time perform/grant index */
} jq_op_info;

struct jq_rt;

typedef struct jq_builtin_info {
  uint32_t ordinal;
  uint32_t arity;
  const char *name; /* feeds <builtin n> and the intrinsics table */
  jq_value (*fn)(struct jq_rt *, const jq_value *); /* consumes its arguments */
} jq_builtin_info;

/* Per-run context. Compiled main wires the constructor values intrinsics
 * return (booleans; orderings arrive with the compare intrinsics). Effects
 * state lands here in task 70. */
/* one installed in-language handler clause: op ordinal -> clause closure.
   kind selects the perform protocol (task 71): a TAIL clause is called
   directly at the perform site (its return IS the resume, task 70); a
   CAPTURING clause suspends — jq_perform records the pending capture and
   returns JQ_SUSPEND, and the covering jq_handle2 dispatch (marked by [hf],
   its handler frame) slices the frame stack into a resumption and runs the
   clause against the outer continuation. Zero-initialized entries are TAIL
   with no mark, which is exactly task 70's shape. */
enum jq_clause_kind { JQ_CLAUSE_TAIL = 0, JQ_CLAUSE_CAPTURING = 1 };

typedef struct jq_handler_entry {
  uint32_t op_ord;
  jq_value clause;
  uint8_t kind;      /* enum jq_clause_kind */
  bool once;         /* captured resumption gets the per-instance once backstop */
  jq_block *hf;      /* CAPTURING only: the owning handler frame on rt->ks */
} jq_handler_entry;

/* pending capture (task 71): set by jq_perform when a CAPTURING clause
   matches, consumed by the covering dispatch when JQ_SUSPEND reaches it */
typedef struct jq_pending {
  jq_value clause; /* dup of the matched entry's clause */
  jq_value args[8];
  uint16_t n_args;
  bool once;
  jq_block *mark; /* the matched entry's handler frame */
} jq_pending;

typedef struct jq_rt {
  jq_value v_true;
  jq_value v_false;
  jq_value v_less;
  jq_value v_equal;
  jq_value v_greater;
  jq_value v_nil;                /* list-building intrinsics (text.split) */
  const jq_con_info *ci_cons;
  const jq_con_info *ci_pair;    /* mk-pair, for the dist intrinsics (task 71) */
  const jq_con_info *ci_some;    /* option some, for the code intrinsics (task 73) */
  jq_value v_none;               /* option none, static (task 73) */
  const jq_con_info *ci_ok;      /* Result constructors for validated host boundaries */
  const jq_con_info *ci_err;
  uint16_t apply_n; /* argument count for the next jq_apply (set by the caller
                       immediately before the call: musttail forces jq_apply
                       onto the uniform signature, so n travels here) */
  /* trampoline stash (task 83, live only when JQ_HAVE_MUSTTAIL is 0): the
     pending tail call between a JQ_TAILCALL return and its drive. Nothing
     runs in between except returns, so one cell suffices; apply_n rides
     alongside for a stashed jq_apply. */
  void *tc_fn; /* jq_fn; void* keeps the struct free of the typedef order */
  jq_value tc_clo;
  jq_value tc_args[8];
  /* effects (task 70): the handler stack, the grant table, and op metadata.
     Perform searches the stack top-down for the nearest cover; a clause body
     runs against the OUTER continuation, so the entries above (and including)
     the match are hidden for the call (see jq_perform). Root grants are the
     --allow natives; ungranted, uncovered ops die per the interpreter's
     contract (unhandled = exit 3). */
  jq_handler_entry *hs;
  uint32_t hs_len;
  uint32_t hs_cap;
  jq_value (**grants)(struct jq_rt *, const jq_value *); /* by op ordinal */
  const jq_op_info **op_meta; /* by op ordinal, for error rendering */
  uint32_t n_ops;
  /* the frame stack (task 71): suspended-activation blocks, innermost on
     top — the runtime image of the interpreter's kont. Frame-style code
     pushes its frame before a suspendable call and pops it on a normal
     return; on JQ_SUSPEND the frame stays for the capture slice. Handler
     frames (jq_handle2) sit in the same stack so a slice [hf .. top] is
     exactly the interpreter's [frames since the handler] + FHandle. */
  jq_block **ks;
  uint32_t ks_len;
  uint32_t ks_cap;
  uint32_t cap_depth; /* installed CAPTURING entries; 0 = no suspension can
                         happen, frame saves may be skipped */
  jq_pending pending;
  /* re-entry hand-off: a frame's code wrapper stashes the frame and the
     incoming value here and calls the machine through its uniform entry;
     the machine's prologue takes them, restores its locals, and jumps to
     the recorded resume point */
  jq_block *re_frame;
  jq_value re_val;
  /* dist (task 72): the sample/observe ordinals (UINT32_MAX when the
     program reaches neither), the root sampler's RNG state (--seed), and
     the LW driver's unhandled-rendering override (the interpreter names
     the pseudo-effect "(not handled during inference)" for ops that reach
     the root during a weighted run) */
  uint32_t ord_sample;
  uint32_t ord_observe;
  int64_t dist_rng;
  const char *unhandled_effect_override;
  /* LW isolation (task 72): perform's handler search stops above hs_floor
     (the interpreter runs each weighted model as a fresh state machine, so
     outer in-language handlers are invisible to it — entries below the
     floor stay untouched); lw points at the driver's per-run state, giving
     sample/observe their ROOT interception — after grants, exactly the
     interpreter's ladder (in-language above the floor, then grants, then
     the inference driver, then unhandled). */
  uint32_t hs_floor;
  void *lw;
} jq_rt;

/* The uniform compiled-function signature: clang's musttail requires caller
 * and callee prototypes to match, so every compiled function takes (rt, clo,
 * a0..a7) with JQ_UNIT padding; arity is capped at 8 by the build driver.
 * Members ignore clo; lifted lambdas read their environment from it. All
 * value arguments (clo included) are owned by the callee. */
#define JQ_MAX_ARITY 8
#define JQ_PARAMS                                                              \
  jq_rt *rt, jq_value clo, jq_value a0, jq_value a1, jq_value a2,              \
      jq_value a3, jq_value a4, jq_value a5, jq_value a6, jq_value a7
typedef jq_value (*jq_fn)(JQ_PARAMS);

/* Guaranteed tail calls (task 76): clang has the musttail statement
 * attribute everywhere we support; GCC grew the same spelling in 15. On
 * older toolchains the trampoline (task 83) takes over: a tail site
 * stashes {fn, clo, args} in rt and returns the JQ_TAILCALL sentinel,
 * and every non-tail call site hops the chain in a driver loop, so tail
 * depth is O(1) stack on every toolchain. The emitted C is identical in
 * both worlds — JQ_TAIL_RETURN and JQ_HOP select per toolchain here.
 * Self recursion loopifies at compile time everywhere and needs neither. */
#if defined(__clang__) || (defined(__GNUC__) && __GNUC__ >= 15)
#define JQ_MUSTTAIL __attribute__((musttail))
#define JQ_HAVE_MUSTTAIL 1
#else
#define JQ_MUSTTAIL
#define JQ_HAVE_MUSTTAIL 0
#endif

/* --- compiled-program support (task 67; jq_apply.c, jq_intrinsics.c) --- */

/* Generic application: dispatches on the callee tag (closure, builtin,
 * constructor saturation, op/resume later) with the interpreter's exact
 * error texts. Uniform jq_fn signature (musttail-compatible from compiled
 * tail calls and INTO closure code): the callee travels in the clo slot and
 * the live argument count in rt->apply_n, set by the caller immediately
 * before the call. Consumes the callee and the live arguments. */
jq_value jq_apply(JQ_PARAMS);

/* runs the program body on a large-stack thread (jq_main.c) */
int jq_run_main(jq_rt *rt, void (*body)(jq_rt *));

/* --- effects (task 70; jq_effects.c) --- */

/* push/pop are balanced by the compiled handle construct; push takes
   ownership of the clause closures, pop releases them */
void jq_handle_push(jq_rt *rt, uint32_t n, const jq_handler_entry *entries);
void jq_handle_pop(jq_rt *rt, uint32_t n);
/* performs op [op_ord] with [n] owned args; returns the clause's value
   (tail-resumptive: the clause's return IS the resume), or JQ_SUSPEND when
   a CAPTURING clause matched (rt->pending set; unwind to its dispatch) */
jq_value jq_perform(jq_rt *rt, uint32_t op_ord, uint16_t n, const jq_value *args);

/* --- capturing continuations (task 71; jq_frames.c) --- */

/* The suspension sentinel: returned instead of a value when a capture is
   unwinding the C stack. Compared by identity only; static, so stray
   dup/drop is a no-op. Frame-style code must check every suspendable
   call's result and propagate. */
/* --- code values (task 73; jq_code.c, printing in jq_show.c) ---

   A CODE block is one form node: n = 1 + 2*argc words.
     payload[0]        the head, an owned TEXT value
     payload[1 + 2i]   arg i's kind (raw word, jq_code_kind_t)
     payload[2 + 2i]   arg i's datum, an owned jq_value:
                       FORM -> CODE, INT -> tagged int, REAL -> REAL block,
                       TEXT/SYM -> TEXT, HASH -> HASH block
   Scope marks are interpreter metadata: inline printing never shows meta
   and code.eq? ignores it, so the native tier carries none (the plan's
   task-73 direction). */
typedef enum {
  JQ_CA_FORM = 0,
  JQ_CA_INT = 1,
  JQ_CA_REAL = 2,
  JQ_CA_TEXT = 3,
  JQ_CA_SYM = 4,
  JQ_CA_HASH = 5,
} jq_code_kind_t;

static inline uint16_t jq_code_argc(jq_value v) {
  return (uint16_t)((jq_block_of(v)->n - 1) / 2);
}
static inline jq_value jq_code_head(jq_value v) {
  return (jq_value)jq_block_of(v)->payload[0];
}
static inline uint64_t jq_code_kind(jq_value v, uint16_t i) {
  return jq_block_of(v)->payload[1 + 2 * (uint32_t)i];
}
static inline jq_value jq_code_datum(jq_value v, uint16_t i) {
  return (jq_value)jq_block_of(v)->payload[2 + 2 * (uint32_t)i];
}
static inline bool jq_is_code(jq_value v) {
  return jq_is_ptr(v) && jq_block_of(v)->tag == JQ_CODE;
}
static inline bool jq_is_hash(jq_value v) {
  return jq_is_ptr(v) && jq_block_of(v)->tag == JQ_HASH;
}

/* allocate a node with the head and argc slots unset; fill each arg with
   jq_code_set (datum ownership transfers in) */
jq_value jq_code_node(jq_value head_text, uint16_t argc);
static inline void jq_code_set(jq_value code, uint16_t i, uint64_t kind, jq_value datum) {
  jq_block_of(code)->payload[1 + 2 * (uint32_t)i] = kind;
  jq_block_of(code)->payload[2 + 2 * (uint32_t)i] = (uint64_t)datum;
}

/* Form.equal_ignoring_meta: heads and args structurally, reals with
   OCaml compare semantics (nan = nan, -0. = 0.) */
bool jq_code_eq(jq_value a, jq_value b);

/* Printer.inline_form as a malloc'd C string (jq_show.c owns the port) */
char *jq_code_inline(jq_value v);
/* Printer.scalar_to_string for one arg (malloc'd) */
char *jq_code_scalar(uint64_t kind, jq_value datum);
/* code.diff's rendering: "identical" or "; "-joined divergences (malloc'd) */
char *jq_code_diff_render(jq_value a, jq_value b);

/* the splice guard: unquote results must be code (eval.ml's rt_type) */
jq_value jq_code_splice_guard(jq_rt *rt, jq_value v);

extern jq_block jq_suspend_block;
#define JQ_SUSPEND (jq_of_block(&jq_suspend_block))

/* the trampoline sentinel (task 83): "the return value is a stashed tail
   call — drive it". Never observable as a program value. */
extern jq_block jq_tailcall_block;
#define JQ_TAILCALL (jq_of_block(&jq_tailcall_block))

/* stash a tail call and return the sentinel; drive a stashed chain until a
   real value (or JQ_SUSPEND) comes back. jq_frames.c owns both. */
jq_value jq_tc_stash(jq_rt *rt, jq_fn f, jq_value clo, const jq_value *args);
jq_value jq_tc_drive(jq_rt *rt, jq_value v);

#if JQ_HAVE_MUSTTAIL
#define JQ_TAIL_RETURN(f, rt, c, ...)                                          \
  JQ_MUSTTAIL return f(rt, c, __VA_ARGS__)
#define JQ_HOP(rt, v) (v)
#else
#define JQ_TAIL_RETURN(f, rt, c, ...)                                          \
  return jq_tc_stash(rt, (jq_fn)(f), c, (const jq_value[]){ __VA_ARGS__ })
#define JQ_HOP(rt, v) jq_tc_drive(rt, v)
#endif

/* frame re-entry code: called with the (owned) frame and the value the
   suspended call site is resumed with; returns the activation's value */
typedef jq_value (*jq_frame_fn)(jq_rt *, jq_block *, jq_value);

/* frame payload: [0] code, [1] resume index, [2] aux, [3..] owned slots
   (ownership: borrowed mirrors of the C locals while on rt->ks; they
   become owned when the activation abandons them by returning JQ_SUSPEND,
   and every captured frame owns its slots) */
static inline jq_frame_fn jq_frame_code(jq_block *f) {
  return (jq_frame_fn)f->payload[0];
}
static inline uint64_t jq_frame_ix(jq_block *f) { return f->payload[1]; }
static inline uint64_t jq_frame_aux(jq_block *f) { return f->payload[2]; }
static inline jq_value *jq_frame_slots(jq_block *f) {
  return (jq_value *)&f->payload[3];
}
static inline uint16_t jq_frame_n_slots(jq_block *f) {
  return (uint16_t)(f->n - 3);
}

jq_block *jq_frame_alloc(jq_frame_fn code, uint64_t ix, uint64_t aux, uint16_t n_slots);
void jq_ks_push(jq_rt *rt, jq_block *f);
static inline void jq_ks_pop(jq_rt *rt) { rt->ks_len--; }

/* the capturing-handle driver: pushes its handler frame + entries (entry
   clauses arrive owned; kind/hf fields are filled here), runs the thunk,
   dispatches captures. A TAIL-kind entry keeps the task-70 direct-call
   protocol at the perform site. Returns the handle's value or propagates
   JQ_SUSPEND. */
jq_value jq_handle2(jq_rt *rt, uint32_t n, const jq_handler_entry *entries, jq_value thunk,
                    jq_value ret_clause);

/* applies a resumption (jq_apply's JQ_RESUME case): clones the captured
   chain (copy-on-resume) and drives it with [v]; the interpreter's
   "frames @ k" at the application site */
jq_value jq_resume(jq_rt *rt, jq_value resume, jq_value v);

/* grant natives (jq_grants.c), installed into rt->grants by generated main
   according to the binary's --allow flags */
jq_value jq_g_print(jq_rt *rt, const jq_value *args);
jq_value jq_g_read_line(jq_rt *rt, const jq_value *args);
jq_value jq_g_now(jq_rt *rt, const jq_value *args);
jq_value jq_g_sleep(jq_rt *rt, const jq_value *args);
jq_value jq_g_fs_read(jq_rt *rt, const jq_value *args);
jq_value jq_g_fs_write(jq_rt *rt, const jq_value *args);
jq_value jq_g_fs_list_dir(jq_rt *rt, const jq_value *args);
jq_value jq_g_dist_sample(jq_rt *rt, const jq_value *args);
jq_value jq_g_dist_observe(jq_rt *rt, const jq_value *args);
jq_value jq_g_dist_draw(jq_rt *rt, jq_value d); /* validated draw core */
jq_value jq_g_infer_complete(jq_rt *rt, const jq_value *args);

/* "no clause matched the value %s", exit 2 (Runtime_err.Match_failure) */
void jq_match_fail(jq_rt *rt, jq_value scrutinee) __attribute__((noreturn));

/* interpreter lit_matches for reals: nan matches nan, -0.0 matches +0.0 */
static inline bool jq_real_lit_match(double a, double b) {
  return (a != a && b != b) || a == b || (a == 0.0 && b == 0.0);
}

/* intrinsics (each consumes its arguments; names mangle . and - to _) */
jq_value jq_i_add(jq_rt *rt, const jq_value *a);
jq_value jq_i_sub(jq_rt *rt, const jq_value *a);
jq_value jq_i_mul(jq_rt *rt, const jq_value *a);
jq_value jq_i_div(jq_rt *rt, const jq_value *a);
jq_value jq_i_mod(jq_rt *rt, const jq_value *a);
jq_value jq_i_eq(jq_rt *rt, const jq_value *a);
jq_value jq_i_lt(jq_rt *rt, const jq_value *a);
jq_value jq_i_add_real(jq_rt *rt, const jq_value *a);
jq_value jq_i_sub_real(jq_rt *rt, const jq_value *a);
jq_value jq_i_mul_real(jq_rt *rt, const jq_value *a);
jq_value jq_i_div_real(jq_rt *rt, const jq_value *a);
jq_value jq_i_lt_real(jq_rt *rt, const jq_value *a);
jq_value jq_i_real_gt_q(jq_rt *rt, const jq_value *a);
jq_value jq_i_real_gte_q(jq_rt *rt, const jq_value *a);
jq_value jq_i_real_lte_q(jq_rt *rt, const jq_value *a);
jq_value jq_i_text_length(jq_rt *rt, const jq_value *a);
jq_value jq_i_text_concat(jq_rt *rt, const jq_value *a);
jq_value jq_i_text_join(jq_rt *rt, const jq_value *a);
jq_value jq_i_text_join_variadic_v1(jq_rt *rt, const jq_value *a, uint16_t n);
jq_value jq_i_int_compare(jq_rt *rt, const jq_value *a);
jq_value jq_i_text_compare(jq_rt *rt, const jq_value *a);
jq_value jq_i_text_trim(jq_rt *rt, const jq_value *a);
jq_value jq_i_text_split(jq_rt *rt, const jq_value *a);
jq_value jq_i_text_empty_q(jq_rt *rt, const jq_value *a);
jq_value jq_i_text_from_int(jq_rt *rt, const jq_value *a);
jq_value jq_i_support(jq_rt *rt, const jq_value *a);
jq_value jq_i_pmf(jq_rt *rt, const jq_value *a);
jq_value jq_i_dist_sample_lw(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_of_int(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_of_real(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_of_hash(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_of_text(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_to_int(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_to_text(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_form(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_un_form(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_eq_q(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_diff(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_render(jq_rt *rt, const jq_value *a);
jq_value jq_i_code_hash(jq_rt *rt, const jq_value *a);
jq_value jq_i_hash_parse(jq_rt *rt, const jq_value *a);
jq_value jq_i_hash_to_text(jq_rt *rt, const jq_value *a);
jq_value jq_i_debug_inspect(jq_rt *rt, const jq_value *a);
/* the LW driver's root interception (jq_perform's ladder, jq_intrinsics.c) */
jq_value jq_lw_sample(jq_rt *rt, jq_value dv);
jq_value jq_lw_observe(jq_rt *rt, jq_value dv, jq_value v);


/* --- constructors (jq_alloc.c) --- */

jq_block *jq_alloc_block(uint8_t tag, uint8_t flags, uint16_t n);
/* release a block shell: pooled blocks return to their freelist, everything
   else to libc. EVERY block release must come through here (the free walk,
   reuse-token leftovers, consumed frames). */
void jq_block_free(jq_block *b);
jq_value jq_tuple(uint32_t n, const jq_value *items); /* items owned; n guarded <= 65535 */
jq_value jq_con(const jq_con_info *info, const jq_value *fields); /* owned */
jq_value jq_real(double d);
jq_value jq_text(const uint8_t *bytes, uint64_t len); /* bytes copied */
jq_value jq_hash(const uint8_t bytes[32]);
jq_value jq_secret(const uint8_t *bytes, uint64_t len); /* bytes copied, opaque */
/* env values owned; self_slot < env_n marks a non-owning slot (stored without
   dup by the caller per the cycle rule), self_slot == UINT16_MAX for none */
jq_value jq_closure(void *code, uint16_t arity, uint16_t env_n,
                    const jq_value *env, uint16_t self_slot);

/* --- accessors --- */

/* TUPLE only: CON and CLOSURE keep info/code words in n's count */
static inline uint16_t jq_tuple_arity(jq_value v) { return jq_block_of(v)->n; }
static inline jq_value *jq_fields(jq_value v) {
  return (jq_value *)jq_block_of(v)->payload;
}
static inline const jq_con_info *jq_con_info_of(jq_value v) {
  return (const jq_con_info *)jq_block_of(v)->payload[0];
}
static inline jq_value *jq_con_fields(jq_value v) {
  return (jq_value *)&jq_block_of(v)->payload[1];
}
static inline uint16_t jq_con_arity(jq_value v) {
  return (uint16_t)(jq_block_of(v)->n - 1);
}
static inline double jq_real_val(jq_value v) {
  union { uint64_t u; double d; } c = { .u = jq_block_of(v)->payload[0] };
  return c.d;
}
static inline uint64_t jq_text_len(jq_value v) {
  return jq_block_of(v)->payload[0];
}
static inline const uint8_t *jq_text_bytes(jq_value v) {
  return (const uint8_t *)&jq_block_of(v)->payload[1];
}
static inline const uint8_t *jq_hash_bytes(jq_value v) {
  return (const uint8_t *)&jq_block_of(v)->payload[0];
}
static inline bool jq_is_secret(jq_value v) {
  return jq_is_ptr(v) && jq_block_of(v)->tag == JQ_SECRET;
}
static inline uint64_t jq_secret_len(jq_value v) {
  return jq_block_of(v)->payload[0];
}
static inline const uint8_t *jq_secret_bytes(jq_value v) {
  return (const uint8_t *)&jq_block_of(v)->payload[1];
}

/* closure payload: [0] code ptr, [1] arity | (self_slot+1) << 16, [2..] env */
static inline void *jq_closure_code(jq_value v) {
  return (void *)jq_block_of(v)->payload[0];
}
static inline uint16_t jq_closure_arity(jq_value v) {
  return (uint16_t)(jq_block_of(v)->payload[1] & 0xffff);
}
/* returns env index of the non-owning self slot, or -1 */
static inline int32_t jq_closure_self_slot(jq_value v) {
  return (int32_t)((jq_block_of(v)->payload[1] >> 16) & 0xffffffff) - 1;
}
static inline jq_value *jq_closure_env(jq_value v) {
  return (jq_value *)&jq_block_of(v)->payload[2];
}
static inline uint16_t jq_closure_env_n(jq_value v) {
  return (uint16_t)(jq_block_of(v)->n - 2);
}

/* --- reference counting (jq_rc.c) --- */

/* the free walk (out of line): fields released with an explicit worklist,
   never C recursion; the block shells route through jq_block_free */
void jq_free_walk(jq_block *b);

/* dup/drop fast paths live here (task 85) so every unit inlines them
   without LTO. A drop of a statically-known immortal (the unit block at
   every known call's clo slot) becomes an inlined load-compare-skip —
   the no-op executes, but the out-of-line call task 79's decline review
   found surviving per fib node is gone, with its ABI spills. */
static inline void jq_dup(jq_value v) {
  if (jq_is_int(v)) return;
  jq_block *b = jq_block_of(v);
  if (b->rc != JQ_RC_STATIC) b->rc++;
}

static inline void jq_drop(jq_value v) {
  if (jq_is_int(v)) return;
  jq_block *b = jq_block_of(v);
  if (b->rc == JQ_RC_STATIC) return;
  if (--b->rc == 0) jq_free_walk(b);
}
/* rc == 1: return the shell for same-shape reuse — its rc STAYS 1, its
   fields are NOT dropped, and the caller now owns both (reuse the shell as
   the new value, or drop each field and free it). Otherwise decrement and
   return NULL. */
jq_block *jq_drop_reuse(jq_value v);

/* Perceus reuse (task 68): [jq_reuse_take] is jq_drop_reuse for a dying CON
   scrutinee — on a unique shell it releases the old fields and returns the
   shell; otherwise it decrements and returns NULL. [jq_con_reuse] fills a
   taken shell (or allocates when NULL). A taken-but-unused shell is plain
   free()d at scope exit. */
jq_block *jq_reuse_take(jq_value v);
jq_value jq_con_reuse(jq_block *shell, const jq_con_info *info,
                      const jq_value *fields);

#endif /* JQ_VALUE_H */
