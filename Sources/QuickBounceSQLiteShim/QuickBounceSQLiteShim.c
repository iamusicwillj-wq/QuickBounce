#include "QuickBounceSQLiteShim.h"

const char *qb_sqlite_runtime_version(void)
{
    return sqlite3_libversion();
}
