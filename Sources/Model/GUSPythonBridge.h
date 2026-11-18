#ifndef GUS_PYTHON_BRIDGE_H
#define GUS_PYTHON_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Executes a Python 3 script inside the embedded pocketpy v2.2.0 VM with:
/// - PK_ENABLE_OS = 0 (no host OS / process / raw file I/O primitives)
/// - PK_ENABLE_WATCHDOG = 1 (bytecode instruction watchdog timeout)
/// - stdc raw-pointer module disabled and cleared
/// - Optional `input_text` exposed as `INPUT_TEXT` and parsed `INPUT` (if JSON) in `__main__`
/// - Built-in pure-Python `csv` helper module (`csv.parse`, `csv.DictReader`, `csv.reader`)
///
/// Returns 0 on success, non-zero on syntax/runtime/timeout error.
int gus_python_eval(
    const char * script,
    const char * input_text,
    int32_t timeout_ms,
    char * out_stdout,
    size_t out_stdout_capacity,
    char * out_error,
    size_t out_error_capacity,
    int64_t * out_duration_ms
);

/// Returns the pocketpy runtime version string (e.g. "pocketpy 2.2.0 (PK_ENABLE_OS=0, WATCHDOG=1)").
const char * gus_python_version_info(void);

#ifdef __cplusplus
}
#endif

#endif /* GUS_PYTHON_BRIDGE_H */
