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
vc_status vc_host_query(vc_host *host, const unsigned char *selector, size_t len, vc_buf *out);
void vc_buf_free(vc_buf buf);

#ifdef __cplusplus
}
#endif

#endif /* VERDE_CLIENT_H */
