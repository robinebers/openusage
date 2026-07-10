#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ou_shim.h"

typedef int (*sqlite3_open_v2_t)(const char *, sqlite3 **, int, const char *);
typedef int (*sqlite3_close_t)(sqlite3 *);
typedef int (*sqlite3_prepare_v2_t)(sqlite3 *, const char *, int, void **, const char **);
typedef int (*sqlite3_step_t)(void *);
typedef const unsigned char *(*sqlite3_column_text_t)(void *, int);
typedef int (*sqlite3_finalize_t)(void *);

static HMODULE g_sqlite_dll;
static sqlite3_open_v2_t p_sqlite3_open_v2;
static sqlite3_close_t p_sqlite3_close;
static sqlite3_prepare_v2_t p_sqlite3_prepare_v2;
static sqlite3_step_t p_sqlite3_step;
static sqlite3_column_text_t p_sqlite3_column_text;
static sqlite3_finalize_t p_sqlite3_finalize;
typedef int (*sqlite3_exec_t)(sqlite3 *, const char *, int (*)(void *, int, char **, char **), void *, char **);

static sqlite3_exec_t p_sqlite3_exec;

static int load_sqlite(void) {
    if (g_sqlite_dll) {
        return 1;
    }
    g_sqlite_dll = LoadLibraryW(L"winsqlite3.dll");
    if (!g_sqlite_dll) {
        return 0;
    }
#define LOAD(name)                                                                                 \
    p_##name = (name##_t)GetProcAddress(g_sqlite_dll, #name);                                      \
    if (!p_##name) {                                                                               \
        return 0;                                                                                  \
    }
    LOAD(sqlite3_open_v2);
    LOAD(sqlite3_close);
    LOAD(sqlite3_prepare_v2);
    LOAD(sqlite3_step);
    LOAD(sqlite3_column_text);
    LOAD(sqlite3_finalize);
    LOAD(sqlite3_exec);
#undef LOAD
    return 1;
}

int ou_sqlite_open_readonly(const char *path, sqlite3 **db) {
    if (!load_sqlite()) {
        return -1;
    }
    return p_sqlite3_open_v2(path, db, OU_SQLITE_OPEN_READONLY, NULL);
}

int ou_sqlite_close(sqlite3 *db) {
    if (!p_sqlite3_close) {
        return -1;
    }
    return p_sqlite3_close(db);
}

int ou_sqlite_query_scalar_text(sqlite3 *db, const char *sql, char **out) {
    *out = NULL;
    if (!load_sqlite()) {
        return -1;
    }
    void *stmt = NULL;
    int rc = p_sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    if (rc != OU_SQLITE_OK) {
        return rc;
    }
    rc = p_sqlite3_step(stmt);
    if (rc == 100) { /* SQLITE_ROW */
        const unsigned char *text = p_sqlite3_column_text(stmt, 0);
        if (text) {
            size_t len = strlen((const char *)text);
            char *copy = (char *)malloc(len + 1);
            if (!copy) {
                p_sqlite3_finalize(stmt);
                return -1;
            }
            memcpy(copy, text, len + 1);
            *out = copy;
        }
        rc = OU_SQLITE_OK;
    } else if (rc == 101) { /* SQLITE_DONE — no row */
        rc = OU_SQLITE_OK;
    }
    p_sqlite3_finalize(stmt);
    return rc;
}

void ou_sqlite_free_string(char *p) {
    free(p);
}

int ou_sqlite_write_fixture(const char *path, const char *key, const char *value) {
    if (!load_sqlite() || !p_sqlite3_exec) {
        return -1;
    }
    sqlite3 *db = NULL;
    const int openFlags = 0x00000002 | 0x00000004; /* SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE */
    int rc = p_sqlite3_open_v2(path, &db, openFlags, NULL);
    if (rc != OU_SQLITE_OK) {
        return rc;
    }
    char *err = NULL;
    const char *ddl = "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);";
    rc = p_sqlite3_exec(db, ddl, NULL, NULL, &err);
    if (rc != OU_SQLITE_OK) {
        if (err) {
            free(err);
        }
        p_sqlite3_close(db);
        return rc;
    }
    char *sql = NULL;
    size_t sql_len = strlen(key) + strlen(value) + 128;
    sql = (char *)malloc(sql_len);
    if (!sql) {
        p_sqlite3_close(db);
        return -1;
    }
    snprintf(sql, sql_len,
             "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('%s', '%s');",
             key, value);
    rc = p_sqlite3_exec(db, sql, NULL, NULL, &err);
    free(sql);
    if (err) {
        free(err);
    }
    p_sqlite3_close(db);
    return rc;
}
