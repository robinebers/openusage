#ifndef OU_SHIM_H
#define OU_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* SQLite (winsqlite3.dll) — read-only query helpers */
#define OU_SQLITE_OK 0
#define OU_SQLITE_BUSY 5
#define OU_SQLITE_LOCKED 6
#define OU_SQLITE_OPEN_READONLY 0x00000001

typedef struct sqlite3 sqlite3;

int ou_sqlite_open_readonly(const char *path, sqlite3 **db);
int ou_sqlite_close(sqlite3 *db);
/// Returns OU_SQLITE_OK and sets *out (malloc'd UTF-8) on success; *out is NULL when no row.
/// On failure returns the sqlite error code (or -1 for load/prepare errors).
int ou_sqlite_query_scalar_text(sqlite3 *db, const char *sql, char **out);
void ou_sqlite_free_string(char *p);

/// Test/fixture helper: create `ItemTable` and insert one key/value pair (read-write create).
int ou_sqlite_write_fixture(const char *path, const char *key, const char *value);

/* Windows Credential Manager (advapi32) — read generic password blob as UTF-8 bytes */
/// Returns 1 on success with malloc'd *out (NUL-terminated copy of CredentialBlob); 0 when not found.
int ou_cred_read_generic_utf8(const wchar_t *target, char **out, size_t *out_len);
void ou_cred_free_string(char *p);

/* Named pipe — user-restricted IPC (CreateNamedPipeW) */
typedef void *ou_pipe_handle;

/// Create a duplex byte-mode named pipe with a DACL limited to the current user + SYSTEM.
/// Returns 1 on success; *out receives the pipe handle. Returns 0 on failure.
int ou_pipe_create_user_restricted(const wchar_t *name, ou_pipe_handle *out);
/// Block until a client connects. Returns 1 on success, 0 on failure.
int ou_pipe_wait_client(ou_pipe_handle pipe);
/// Disconnect the current client so the pipe can accept another connection.
void ou_pipe_disconnect(ou_pipe_handle pipe);
/// Close the pipe handle.
void ou_pipe_close(ou_pipe_handle pipe);
/// Read one newline-delimited line (without the newline). Caller frees with ou_pipe_free_string.
/// Returns 1 on success, 0 on EOF/error.
int ou_pipe_read_line(ou_pipe_handle pipe, char **out, size_t *out_len);
/// Write a line plus '\n'. Returns 1 on success.
int ou_pipe_write_line(ou_pipe_handle pipe, const char *line);
void ou_pipe_free_string(char *p);

#ifdef __cplusplus
}
#endif

#endif /* OU_SHIM_H */
