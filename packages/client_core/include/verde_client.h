/*
 * Verde mobile client core: C ABI.
 *
 * This header must match the `export`s in src/root.zig; the host
 * `zig build test` step compiles tests/abi_smoke.c against it and the shared
 * library to keep the two in sync.
 */
#ifndef VERDE_CLIENT_H
#define VERDE_CLIENT_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Returns the core version as a static, NUL-terminated UTF-8 string.
 * The string lives for the life of the process; callers must not free it.
 */
const char *vc_version(void);

#ifdef __cplusplus
}
#endif

#endif /* VERDE_CLIENT_H */
