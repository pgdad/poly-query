/*
 * exec.inc - executor structures shared by exec.S, join.S and the
 * parallel / vectorized execution modules.
 */
#ifndef EXEC_INC
#define EXEC_INC

/* aggregate state */
#define AS_COUNT 0
#define AS_LO    8
#define AS_HI    16
#define AS_VAL   24
#define AS_HAS   32
#define AS_SET   40    /* HashTable* of seen values (DISTINCT aggregates) */
#define AS_SIZE  48

/* execution state of one query block (arena allocated) */
#define XS_PLAN   0
#define XS_CTX    8    /* EvalCtx, EC_SIZE bytes */
#define XS_TABLES 72   /* Table*[nrv] */
#define XS_W      80   /* tuple width = max(nrv, 1) */
#define XS_TS     88   /* TupleSet* (after FROM and WHERE) */
#define XS_ROWS   96   /* Vec of rows: 96..127 */
#define XS_STOP   128  /* stop producing rows after this many (LIMIT pushdown) */
#define XS_PAR    136  /* pexec.S: 0 unknown, 1 parallel ok, 2 serial only */
#define XS_SIZE   144

/* batch size of the batch / vectorized operators (pexec.S, vec.S) */
#define VB 1024

/* tuple set */
#define TS_N    0
#define TS_CAP  8
#define TS_DATA 16
#define TS_W    24
#define TS_SIZE 32

/* IN (subquery) value set */
#define IS_HT    0
#define IS_NULL  8     /* the subquery produced a NULL */
#define IS_ROWS  16    /* number of rows produced */
#define IS_TYPE  24    /* comparison type (key type of IS_HT) */
#define IS_SIZE  32

#endif
