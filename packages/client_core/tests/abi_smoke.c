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
    return 0;
}
