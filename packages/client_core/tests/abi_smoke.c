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
    const unsigned char utility[] = "{\"utility\":\"markdown\",\"text\":\"# hello\"}";
    vc_buf rendered = {0};
    if (vc_host_query(host, utility, sizeof(utility)-1, &rendered) || !rendered.len) return 9;
    if (vc_host_handle(host, stop, sizeof(stop)-1, &batch)) return 6;
    vc_buf_free(batch);
    vc_host_free(host);
    if (!rendered.ptr || rendered.ptr[0] != '{') return 10;
    vc_buf_free(rendered);
    /* Snapshot remains readable after destroying the host. */
    if (snapshot.ptr[0] != '{') return 7;
    vc_buf_free(snapshot);
    vc_buf_free((vc_buf){0});
    vc_host_free(NULL);
    host = (vc_host *)1;
    if (vc_host_new(NULL, 1, &host) != 1 || host) return 8;
    const unsigned char term_config[] = "{\"api_version\":1,\"cols\":20,\"rows\":4,\"scrollback_rows\":10}";
    vc_term *term = NULL;
    if (vc_term_new(term_config, sizeof(term_config)-1, &term) || !term) return 11;
    if (vc_term_write(term, (const unsigned char *)"abc", 3)) return 12;
    if (vc_term_resize(term, 24, 6) || vc_term_scroll(term, 2)) return 13;
    if (vc_term_snapshot(term, &snapshot) || !snapshot.len) return 14;
    vc_term_free(term);
    if (snapshot.ptr[0] != '{') return 15;
    vc_buf_free(snapshot);
    vc_term_free(NULL);
    term = (vc_term *)1;
    if (vc_term_new(NULL, 1, &term) != 1 || term) return 16;
    return 0;
}
