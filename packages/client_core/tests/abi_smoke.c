/* Compiles the public header as C and calls the shared library through it. */
#include "verde_client.h"

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: abi_smoke <expected-version>\n");
        return 2;
    }
    const char *version = vc_version();
    if (version == NULL || strcmp(version, argv[1]) != 0) {
        fprintf(stderr, "vc_version() = %s, want %s\n", version ? version : "(null)", argv[1]);
        return 1;
    }
    const unsigned char config[] = "{\"api_version\":1,\"host_id\":\"abi\",\"label\":\"ABI\",\"https_url\":null,\"wss_url\":null,\"client_revision\":1,\"session_nonce\":\"0123456789abcdef0123456789abcdef\",\"jitter_seed\":1}";
    const unsigned char start[] = "{\"api_version\":1,\"type\":\"start\",\"now_ms\":0,\"wall_time_ms\":0,\"foreground\":true,\"network_available\":true}";
    const unsigned char stop[] = "{\"api_version\":1,\"type\":\"shutdown\",\"now_ms\":1,\"wall_time_ms\":1}";
    vc_host *host = NULL;
    vc_buf batch = {0}, snapshot = {0};
    if (vc_host_new(config, sizeof(config)-1, &host) || !host) return 3;
    if (vc_host_handle(host, start, sizeof(start)-1, &batch) || !batch.len) return 4;
    vc_buf_free(batch);
    if (vc_host_query(host, (const unsigned char *)"hosts", 5, &snapshot) || !snapshot.len) return 5;
    if (vc_host_handle(host, stop, sizeof(stop)-1, &batch)) return 6;
    vc_buf_free(batch);
    vc_host_free(host);
    /* Snapshot remains readable after destroying the host. */
    if (snapshot.ptr[0] != '{') return 7;
    vc_buf_free(snapshot);
    vc_buf_free((vc_buf){0});
    vc_host_free(NULL);
    host = (vc_host *)1;
    if (vc_host_new(NULL, 1, &host) != 1 || host) return 8;
    return 0;
}
