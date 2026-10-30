#include <stdlib.h>
#include <time.h>

// The tests expect UTC days and run in parallel in one process, where TZ is process-wide. Setting it here, when the
// test binary loads, means no test sees the zone change under it (Settings.startTZ is read later, as UTC too).
__attribute__((constructor, used)) static void zagon_tests_utc(void) {
    setenv("TZ", "UTC", 1);
    tzset();
}
