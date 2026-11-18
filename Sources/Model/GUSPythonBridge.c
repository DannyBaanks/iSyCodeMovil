#include "GUSPythonBridge.h"
#include "pocketpy.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static pthread_mutex_t g_py_mutex = PTHREAD_MUTEX_INITIALIZER;
static int g_py_initialized = 0;

static char * g_stdout_buf = NULL;
static size_t g_stdout_cap = 0;
static size_t g_stdout_len = 0;
static int g_stdout_truncated = 0;

static void gus_py_print_callback(const char * text) {
    if (!text || !g_stdout_buf || g_stdout_cap == 0) {
        return;
    }
    size_t len = strlen(text);
    size_t avail = (g_stdout_len + 1 < g_stdout_cap) ? (g_stdout_cap - 1 - g_stdout_len) : 0;
    if (len > avail) {
        if (avail > 0) {
            memcpy(g_stdout_buf + g_stdout_len, text, avail);
            g_stdout_len += avail;
            g_stdout_buf[g_stdout_len] = '\0';
        }
        g_stdout_truncated = 1;
        return;
    }
    memcpy(g_stdout_buf + g_stdout_len, text, len);
    g_stdout_len += len;
    g_stdout_buf[g_stdout_len] = '\0';
}

static char * gus_py_blocked_importfile(const char * path, int * data_size) {
    (void)path;
    if (data_size) {
        *data_size = 0;
    }
    return NULL;
}

static const char * kGUSCSVModuleSource =
    "def _split_csv_line(line, delimiter=','):\n"
    "    fields = []\n"
    "    cur = []\n"
    "    in_quotes = False\n"
    "    i = 0\n"
    "    n = len(line)\n"
    "    while i < n:\n"
    "        ch = line[i]\n"
    "        if ch == '\"':\n"
    "            if in_quotes and i + 1 < n and line[i + 1] == '\"':\n"
    "                cur.append('\"')\n"
    "                i += 2\n"
    "                continue\n"
    "            in_quotes = not in_quotes\n"
    "        elif ch == delimiter and not in_quotes:\n"
    "            fields.append(''.join(cur).strip())\n"
    "            cur = []\n"
    "        else:\n"
    "            cur.append(ch)\n"
    "        i += 1\n"
    "    fields.append(''.join(cur).strip())\n"
    "    return fields\n"
    "\n"
    "def reader(lines, delimiter=','):\n"
    "    if isinstance(lines, str):\n"
    "        lines = lines.splitlines()\n"
    "    out = []\n"
    "    for raw in lines:\n"
    "        s = raw.strip()\n"
    "        if s:\n"
    "            out.append(_split_csv_line(s, delimiter))\n"
    "    return out\n"
    "\n"
    "def DictReader(lines, delimiter=','):\n"
    "    rows = reader(lines, delimiter)\n"
    "    if not rows:\n"
    "        return []\n"
    "    headers = rows[0]\n"
    "    result = []\n"
    "    for r in rows[1:]:\n"
    "        item = {}\n"
    "        for idx in range(len(headers)):\n"
    "            item[headers[idx]] = r[idx] if idx < len(r) else ''\n"
    "        result.append(item)\n"
    "    return result\n"
    "\n"
    "def parse(text, delimiter=','):\n"
    "    return DictReader(text, delimiter)\n";

static const char * kGUSPreludeSource =
    "import json\n"
    "import csv\n"
    "try:\n"
    "    INPUT = json.loads(INPUT_TEXT) if INPUT_TEXT else None\n"
    "except Exception:\n"
    "    INPUT = INPUT_TEXT\n";

static int64_t gus_monotonic_ms(void) {
    return time_monotonic_ns() / 1000000LL;
}

int gus_python_eval(
    const char * script,
    const char * input_text,
    int32_t timeout_ms,
    char * out_stdout,
    size_t out_stdout_capacity,
    char * out_error,
    size_t out_error_capacity,
    int64_t * out_duration_ms
) {
    if (out_stdout && out_stdout_capacity > 0) {
        out_stdout[0] = '\0';
    }
    if (out_error && out_error_capacity > 0) {
        out_error[0] = '\0';
    }
    if (out_duration_ms) {
        *out_duration_ms = 0;
    }
    if (!script || script[0] == '\0') {
        if (out_error && out_error_capacity > 0) {
            snprintf(out_error, out_error_capacity, "Falta el código Python ('script').");
        }
        return -1;
    }

    int32_t clamped_timeout = timeout_ms;
    if (clamped_timeout < 50) clamped_timeout = 50;
    if (clamped_timeout > 15000) clamped_timeout = 15000;

    pthread_mutex_lock(&g_py_mutex);
    int64_t started_ms = gus_monotonic_ms();

    if (!g_py_initialized) {
        py_initialize();
        g_py_initialized = 1;
    } else {
        py_resetvm();
    }

    g_stdout_buf = out_stdout;
    g_stdout_cap = out_stdout_capacity;
    g_stdout_len = 0;
    g_stdout_truncated = 0;

    py_Callbacks * cb = py_callbacks();
    cb->print = gus_py_print_callback;
    cb->importfile = gus_py_blocked_importfile;

    // Register pure-Python `csv` helper module in the fresh VM
    py_GlobalRef csv_mod = py_newmodule("csv");
    if (!py_exec(kGUSCSVModuleSource, "<csv>", EXEC_MODE, csv_mod)) {
        py_clearexc(NULL);
    }

    // Bind INPUT_TEXT in __main__
    py_newstr(py_r0(), input_text ? input_text : "");
    py_setglobal(py_name("INPUT_TEXT"), py_r0());
    if (!py_exec(kGUSPreludeSource, "<prelude>", EXEC_MODE, NULL)) {
        py_clearexc(NULL);
    }

    py_watchdog_begin((py_i64)clamped_timeout);
    bool ok = py_exec(script, "<python_eval>", EXEC_MODE, NULL);
    py_watchdog_end();

    int status = 0;
    if (!ok) {
        status = 1;
        char * formatted = py_formatexc();
        if (out_error && out_error_capacity > 0) {
            snprintf(out_error, out_error_capacity, "%s", formatted ? formatted : "Error de ejecución en Python.");
        }
        if (formatted) {
            py_free(formatted);
        }
        py_clearexc(NULL);
    } else if (g_stdout_truncated && out_stdout && out_stdout_capacity > 64) {
        const char * suffix = "\n[salida truncada]";
        size_t slen = strlen(suffix);
        if (g_stdout_len + slen + 1 < out_stdout_capacity) {
            memcpy(out_stdout + g_stdout_len, suffix, slen + 1);
        }
    }

    py_gc_collect();

    g_stdout_buf = NULL;
    g_stdout_cap = 0;
    g_stdout_len = 0;

    int64_t elapsed = gus_monotonic_ms() - started_ms;
    if (out_duration_ms) {
        *out_duration_ms = elapsed;
    }

    pthread_mutex_unlock(&g_py_mutex);
    return status;
}

const char * gus_python_version_info(void) {
    return "pocketpy " PK_VERSION " (PK_ENABLE_OS=0, PK_ENABLE_WATCHDOG=1, stdc=disabled)";
}
