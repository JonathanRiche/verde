/* Compiles the public header as C and calls the shared library through it. */
#include "verde_client.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int contains(vc_buf buf, const char *needle) {
    size_t n = strlen(needle);
    for (size_t i = 0; buf.ptr && i + n <= buf.len; i++)
        if (memcmp(buf.ptr + i, needle, n) == 0) return 1;
    return 0;
}

/* Exercise the exported ABI, not just Host.handle: this boundary previously
 * rejected valid network completions before the larger engine limit applied. */
static int network_envelope_limits(vc_host *host) {
    const char *prefixes[] = {
        "{\"api_version\":1,\"type\":\"http_response\",\"now_ms\":0,\"wall_time_ms\":0,\"effect_id\":\"missing\",\"generation\":\"1\",\"status\":200,\"headers\":[],\"error\":null,\"body_base64\":\"",
        "{\"api_version\":1,\"type\":\"ws_message\",\"now_ms\":0,\"wall_time_ms\":0,\"socket_id\":\"missing\",\"generation\":\"1\",\"text\":\""
    };
    const size_t payload = 1024 * 1024;
    unsigned char *input = malloc(payload + 512);
    if (!input) return 20;
    vc_buf out = {0};
    for (size_t i = 0; i < 2; i++) {
        size_t prefix = strlen(prefixes[i]);
        memcpy(input, prefixes[i], prefix);
        memset(input + prefix, 'A', payload);
        memcpy(input + prefix + payload, "\"}", 2);
        int code = vc_host_handle(host, input, prefix + payload + 2, &out);
        if (code || !out.len) { free(input); return 21 + (int)i; }
        vc_buf_free(out);
    }
    /* Ordinary events and queries keep their 1 MiB limit. */
    const char *stop = "{\"api_version\":1,\"type\":\"shutdown\",\"now_ms\":0,\"wall_time_ms\":0}";
    memset(input, ' ', payload + 1);
    memcpy(input, stop, strlen(stop));
    int event_code = vc_host_handle(host, input, payload + 1, &out);
    int query_code = vc_host_query(host, input, payload + 1, &out);
    free(input);
    if (event_code != 5 || query_code != 5) return 23;
    if (vc_host_handle(host, NULL, 12 * 1024 * 1024 + 1, &out) != 5 || out.ptr) return 24;
    return 0;
}

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
    int limits = network_envelope_limits(host);
    if (limits) return limits;
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
    /* No key: the pure push opener still returns the generic model. */
    const unsigned char push[] = "{\"api_version\":1,\"envelope\":\"AQ\",\"keys\":[]}";
    vc_buf notice = {0};
    if (vc_push_open(push, sizeof(push)-1, &notice) || !notice.len) return 17;
    if (!contains(notice, "A Verde chat needs attention")) return 18;
    vc_buf_free(notice);
    if (vc_push_open(NULL, 1, &notice) != 1 || notice.ptr) return 19;
    return 0;
}
