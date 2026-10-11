/*
 * http.inc - HTTP/1.1 request descriptor (http.S) and the server's
 * connection / query slot layout (server.S).
 */
#ifndef HTTP_INC
#define HTTP_INC

/* http_parse results */
#define HP_NEED   0     /* incomplete: read more */
#define HP_OK     1     /* complete request described by the Req */
#define HP_BAD    2     /* malformed framing: 400 and close */
#define HP_TOOBIG 3     /* body larger than --max-request-bytes: 413 */

/* parsed request (Req) */
#define RQ_METH    0     /* method bytes */
#define RQ_METHLEN 8
#define RQ_PATH    16    /* request target without the query string */
#define RQ_PATHLEN 24
#define RQ_QS      32    /* query string (after '?') */
#define RQ_QSLEN   40
#define RQ_BODY    48    /* body bytes (chunked bodies decoded in place) */
#define RQ_BODYLEN 56
#define RQ_TOTAL   64    /* bytes of the buffer the request occupies */
#define RQ_CLOSE   72    /* Connection: close / HTTP/1.0 */
#define RQ_EXPECT  80    /* Expect: 100-continue */
#define RQ_HDRLEN  88    /* bytes up to and including the blank line (0 = incomplete) */
#define RQ_CLEN    96    /* Content-Length */
#define RQ_CHUNKED 104
#define RQ_SIZE    112

/* http_send flags */
#define HS_CLOSE   1     /* Connection: close */

/* connection slot (server.S); the query fields describe the request the
 * connection is waiting for (one at a time per connection) */
#define CN_STATE   0     /* CS_* */
#define CN_FD      8
#define CN_BUF     16    /* Buf: received bytes not yet consumed */
#define CN_CLOSE   40    /* close after the current response */
#define CN_DISCARD 48    /* body bytes still to skip (after a 413) */
#define CN_CONT    56    /* "100 Continue" sent for the pending request */
#define CN_DRAINDL 64    /* lingering close deadline (ns) */
#define CN_HUP     72    /* peer hung up while a query was pending */
#define CN_QSTATE  80    /* QS_* */
#define CN_QID     88    /* query id (malloc'd C string) */
#define CN_QKIND   96    /* QK_* */
#define CN_QBODY   104   /* request body copy (malloc'd) */
#define CN_QBLEN   112
#define CN_QSEQ    120   /* admission order (FIFO queue) */
#define CN_QSTART  128   /* arrival time (ns) */
#define CN_QDL     136   /* absolute deadline (ns), 0 = none */
#define CN_QPID    144   /* child process */
#define CN_QCANCEL 152   /* time SIGUSR1 was sent (ns), 0 = not cancelled */
#define CN_QACCT   160   /* completion accounted (metrics / log) */
#define CN_QREQID  168   /* /v1/request: JSON text of the request id (malloc'd) or 0 */
#define CN_QKILL   176   /* error code to report when the parent killed the child */
#define CN_QMETRIC 184   /* counts as a query in the metrics */
/* catalog job (executed by the catalog worker thread) */
#define CN_JKIND   192   /* JK_* */
#define CN_JOP     200   /* forced op (C string) or 0 = the request's "op" */
#define CN_JOK     208   /* HTTP status on success */
#define CN_JQUERY  216   /* account as a query (CREATE / DROP INDEX) */
#define CN_RESP    224   /* response body (malloc'd) */
#define CN_RESPLEN 232
#define CN_RSTATUS 240   /* HTTP status of the response */
#define CN_ISTATUS 248   /* error code, 0 = ok */
#define CN_JREQ    256   /* copy of the Req (malloc'd); points into CN_BUF */
#define CN_JNAME   264   /* table name in the path (raw) */
#define CN_JNLEN   272
#define CN_JNULPOS 280   /* body terminator written in place, restored when done */
#define CN_JNULVAL 288
#define CN_SIZE    296

#define CS_FREE    0
#define CS_READ    1     /* reading / parsing requests */
#define CS_BUSY    2     /* a query is queued or running for this connection */
#define CS_DRAIN   3     /* lingering close: discard input until EOF */

#define QS_NONE    0
#define QS_QUEUED  1
#define QS_RUNNING 2
#define QS_STARTING 3    /* admitted, waiting for the catalog lock to fork */
#define QS_INLINE  4     /* catalog job queued / running in the worker thread */

#define JK_EMPTY   1     /* op on an empty object */
#define JK_BODY    2     /* op on the JSON body (0 op = protocol request) */
#define JK_TABLE   3     /* op on {"table": <path name>} */
#define JK_PUT     4     /* PUT /v1/tables/{name}: load of the raw body */

#define QK_QUERY   1     /* POST /v1/query */
#define QK_STREAM  2     /* POST /v1/query/stream */
#define QK_REQUEST 3     /* POST /v1/request */

/* per-connection record shared with the query's child process */
#define SH_DONE    0     /* 1 = result final (set before the response is written) */
#define SH_STATUS  8     /* error code, 0 = ok */
#define SH_ROWS    16
#define SH_WRITING 24    /* child started writing to the socket */
#define SH_SIZE    32

#endif
