#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <sddl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ou_shim.h"

static int build_user_dacl(PSECURITY_DESCRIPTOR *ppSD) {
    HANDLE hToken = NULL;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &hToken)) {
        return 0;
    }

    DWORD len = 0;
    GetTokenInformation(hToken, TokenUser, NULL, 0, &len);
    PTOKEN_USER pUser = (PTOKEN_USER)malloc(len);
    if (!pUser) {
        CloseHandle(hToken);
        return 0;
    }
    if (!GetTokenInformation(hToken, TokenUser, pUser, len, &len)) {
        free(pUser);
        CloseHandle(hToken);
        return 0;
    }

    LPWSTR sidStr = NULL;
    if (!ConvertSidToStringSidW(pUser->User.Sid, &sidStr)) {
        free(pUser);
        CloseHandle(hToken);
        return 0;
    }

    wchar_t sddl[640];
    /* SY = SYSTEM, <user> = interactive user. */
    int written = swprintf(sddl, 640, L"D:P(A;;GA;;;SY)(A;;GA;;;%s)", sidStr);
    if (written <= 0) {
        LocalFree(sidStr);
        free(pUser);
        CloseHandle(hToken);
        return 0;
    }

    LocalFree(sidStr);
    free(pUser);
    CloseHandle(hToken);

    PSECURITY_DESCRIPTOR pSD = NULL;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &pSD, NULL)) {
        return 0;
    }
    *ppSD = pSD;
    return 1;
}

int ou_pipe_create_user_restricted(const wchar_t *name, ou_pipe_handle *out) {
    *out = NULL;

    PSECURITY_DESCRIPTOR pSD = NULL;
    int hasDacl = build_user_dacl(&pSD);

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = hasDacl ? pSD : NULL;
    sa.bInheritHandle = FALSE;

    HANDLE h = CreateNamedPipeW(
        name,
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES,
        65536,
        65536,
        0,
        &sa);

    if (hasDacl && pSD) {
        LocalFree(pSD);
    }

    if (h == INVALID_HANDLE_VALUE) {
        return 0;
    }
    *out = (ou_pipe_handle)h;
    return 1;
}

int ou_pipe_wait_client(ou_pipe_handle pipe) {
    return ConnectNamedPipe((HANDLE)pipe, NULL) ? 1 : (GetLastError() == ERROR_PIPE_CONNECTED ? 1 : 0);
}

void ou_pipe_disconnect(ou_pipe_handle pipe) {
    DisconnectNamedPipe((HANDLE)pipe);
}

void ou_pipe_close(ou_pipe_handle pipe) {
    CloseHandle((HANDLE)pipe);
}

int ou_pipe_read_line(ou_pipe_handle pipe, char **out, size_t *out_len) {
    *out = NULL;
    *out_len = 0;

    size_t cap = 256;
    size_t len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) {
        return 0;
    }

    for (;;) {
        char ch;
        DWORD read = 0;
        BOOL ok = ReadFile((HANDLE)pipe, &ch, 1, &read, NULL);
        if (!ok || read == 0) {
            ou_pipe_free_string(buf);
            return len > 0 ? 1 : 0;
        }
        if (ch == '\n') {
            break;
        }
        if (ch == '\r') {
            continue;
        }
        if (len + 1 >= cap) {
            cap *= 2;
            char *next = (char *)realloc(buf, cap);
            if (!next) {
                ou_pipe_free_string(buf);
                return 0;
            }
            buf = next;
        }
        buf[len++] = ch;
    }
    buf[len] = '\0';
    *out = buf;
    *out_len = len;
    return 1;
}

int ou_pipe_write_line(ou_pipe_handle pipe, const char *line) {
    if (!line) {
        return 0;
    }
    size_t n = strlen(line);
    DWORD written = 0;
    if (!WriteFile((HANDLE)pipe, line, (DWORD)n, &written, NULL) || written != n) {
        return 0;
    }
    const char nl = '\n';
    if (!WriteFile((HANDLE)pipe, &nl, 1, &written, NULL) || written != 1) {
        return 0;
    }
    return 1;
}

void ou_pipe_free_string(char *p) {
    free(p);
}
