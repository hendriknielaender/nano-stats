// include/nano_stats.h
#ifndef NANO_STATS_H
#define NANO_STATS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Create a new status bar application with the given title
void* nano_stats_create(const char* title);

// Run the application (blocks until termination)
void nano_stats_run(void* app);

// Destroy the application instance
void nano_stats_destroy(void* app);

#ifdef __cplusplus
}
#endif

#endif // NANO_STATS_H

