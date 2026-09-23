#include <stdint.h>
#include <stddef.h>

#define MAX_COVERAGE_POINTS 100000

_Thread_local uintptr_t __sancov_lowest_stack;
uintptr_t coverage_program_counters[MAX_COVERAGE_POINTS];
uint8_t coverage_values[MAX_COVERAGE_POINTS];
size_t coverage_point_count;

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    const uint32_t index = *guard - 1;
    if (index >= MAX_COVERAGE_POINTS) return;
    coverage_values[index] = 1;
    coverage_program_counters[index] = (uintptr_t)__builtin_return_address(0);
}

void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
    if (start == stop || *start != 0) return;
    for (uint32_t *guard = start; guard < stop; guard += 1) {
        if (coverage_point_count >= MAX_COVERAGE_POINTS) return;
        *guard = (uint32_t)(coverage_point_count + 1);
        coverage_point_count += 1;
    }
}