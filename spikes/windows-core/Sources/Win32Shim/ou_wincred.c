#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincred.h>
#include <stdlib.h>
#include <string.h>

#include "ou_shim.h"

int ou_cred_read_generic_utf8(const wchar_t *target, char **out, size_t *out_len) {
    *out = NULL;
    *out_len = 0;
    PCREDENTIALW cred = NULL;
    if (!CredReadW(target, CRED_TYPE_GENERIC, 0, &cred)) {
        return 0;
    }
    size_t len = (size_t)cred->CredentialBlobSize;
    char *buf = (char *)malloc(len + 1);
    if (!buf) {
        CredFree(cred);
        return 0;
    }
    if (len > 0) {
        memcpy(buf, cred->CredentialBlob, len);
    }
    buf[len] = '\0';
    CredFree(cred);
    *out = buf;
    *out_len = len;
    return 1;
}

void ou_cred_free_string(char *p) {
    free(p);
}
