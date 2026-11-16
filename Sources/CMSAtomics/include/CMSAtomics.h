#ifndef CMSATOMICS_H
#define CMSATOMICS_H

#include <stdatomic.h>
#include <stdint.h>

/// Tiny wrapper over a 64-bit atomic, used by SPSCRingBuffer for head/tail counters.
typedef struct {
    _Atomic(uint64_t) value;
} MSAtomicU64;

static inline void ms_atomic_u64_init(MSAtomicU64 *a, uint64_t v) {
    atomic_init(&a->value, v);
}

static inline uint64_t ms_atomic_u64_load_acquire(MSAtomicU64 *a) {
    return atomic_load_explicit(&a->value, memory_order_acquire);
}

static inline void ms_atomic_u64_store_release(MSAtomicU64 *a, uint64_t v) {
    atomic_store_explicit(&a->value, v, memory_order_release);
}

#endif
