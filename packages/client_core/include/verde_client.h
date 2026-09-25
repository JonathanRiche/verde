/*
 * Verde mobile client core: C ABI.
 *
 * This header must match the `export`s in src/root.zig; the host
 * `zig build test` step compiles tests/abi_smoke.c against it and the shared
 * library to keep the two in sync.
 */
#ifndef VERDE_CLIENT_H
#define VERDE_CLIENT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Returns the core version as a static, NUL-terminated UTF-8 string.
 * The string lives for the life of the process; callers must not free it.
 */
const char *vc_version(void);

typedef struct vc_host vc_host;
typedef struct vc_term vc_term;
typedef struct { unsigned char *ptr; size_t len; } vc_buf;
typedef int32_t vc_status;
/* 0 success; 1 invalid argument/JSON; 2 unsupported API revision;
 * 3 allocation failure; 4 invalid lifecycle; 5 resource limit.
 * Serialize all calls on each host. Inputs are borrowed for the call only.
 * Outputs are cleared on failure and survive calls and host destruction.
 * Free each returned buffer exactly once. {NULL,0} is a no-op.
 * Run shutdown and detach callbacks before freeing a host. Free does no I/O.
 */
vc_status vc_host_new(const unsigned char *json, size_t len, vc_host **out);
void vc_host_free(vc_host *host);
vc_status vc_host_handle(vc_host *host, const unsigned char *json, size_t len, vc_buf *out);
/* Pure query; selectors also accept JSON markdown/highlight/diff utilities.
 * See docs/rendering.md for byte offsets, budgets, and query-envelope errors. */
vc_status vc_host_query(vc_host *host, const unsigned char *selector, size_t len, vc_buf *out);
void vc_buf_free(vc_buf buf);
/* Independent serialized VT handle; free never kills the remote session.
 * Snapshot drains device replies only after successful output allocation.
 * Positive scroll deltas move toward older history. */
vc_status vc_term_new(const unsigned char *json, size_t len, vc_term **out);
void vc_term_free(vc_term *term);
vc_status vc_term_write(vc_term *term, const unsigned char *bytes, size_t len);
vc_status vc_term_resize(vc_term *term, uint16_t cols, uint16_t rows);
vc_status vc_term_scroll(vc_term *term, int32_t delta_rows);
vc_status vc_term_snapshot(vc_term *term, vc_buf *out);

#ifdef __cplusplus
}
#endif

#endif /* VERDE_CLIENT_H */
