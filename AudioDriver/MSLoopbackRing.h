// Pure C loopback ring buffer for the MacScreen audio driver.
// Indexed by absolute sample time (frame index modulo capacity). The writer records the
// end of the valid region; readers get silence for frames outside [end - capacity, end).
// No allocation, no locks: safe to call from the Core Audio IO thread.
#ifndef MS_LOOPBACK_RING_H
#define MS_LOOPBACK_RING_H

#include <stdint.h>
#include <string.h>
#include <stdatomic.h>

typedef struct {
    float *samples;          // capacityFrames * channels floats, owned by the caller
    uint32_t capacityFrames;
    uint32_t channels;
    _Atomic int64_t end;     // one past the last frame written
} MSLoopbackRing;

static inline void ms_ring_reset(MSLoopbackRing *r) {
    memset(r->samples, 0, (size_t)r->capacityFrames * r->channels * sizeof(float));
    atomic_store_explicit(&r->end, 0, memory_order_release);
}

static inline void ms_ring_init(MSLoopbackRing *r, float *samples, uint32_t capacityFrames, uint32_t channels) {
    r->samples = samples;
    r->capacityFrames = capacityFrames;
    r->channels = channels;
    ms_ring_reset(r);
}

static inline void ms_ring_zero_range(MSLoopbackRing *r, int64_t start, int64_t frames) {
    for (int64_t i = 0; i < frames; i++) {
        uint32_t slot = (uint32_t)((start + i) % (int64_t)r->capacityFrames);
        memset(r->samples + (size_t)slot * r->channels, 0, r->channels * sizeof(float));
    }
}

// Writes `frames` interleaved frames at sample time `start`, scaled by `gain`.
static inline void ms_ring_write(MSLoopbackRing *r, int64_t start, uint32_t frames, const float *src, float gain) {
    if (start < 0 || frames == 0) return;
    int64_t cap = r->capacityFrames;
    if (frames > cap) {                       // keep only the newest `cap` frames
        src += (size_t)(frames - cap) * r->channels;
        start += frames - cap;
        frames = (uint32_t)cap;
    }
    int64_t end = atomic_load_explicit(&r->end, memory_order_acquire);
    if (start > end) {                        // gap since the last write: make it silence
        int64_t gap = start - end;
        if (gap > cap) gap = cap;
        ms_ring_zero_range(r, start - gap, gap);
    }
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t slot = (uint32_t)((start + i) % cap);
        float *d = r->samples + (size_t)slot * r->channels;
        const float *s = src + (size_t)i * r->channels;
        for (uint32_t c = 0; c < r->channels; c++) d[c] = s[c] * gain;
    }
    int64_t newEnd = start + frames;
    if (newEnd > end) atomic_store_explicit(&r->end, newEnd, memory_order_release);
}

// Reads `frames` interleaved frames starting at sample time `start`; invalid frames are silence.
static inline void ms_ring_read(MSLoopbackRing *r, int64_t start, uint32_t frames, float *dst) {
    size_t ch = r->channels;
    memset(dst, 0, (size_t)frames * ch * sizeof(float));
    if (start < 0 || frames == 0) return;
    int64_t cap = r->capacityFrames;
    int64_t end = atomic_load_explicit(&r->end, memory_order_acquire);
    int64_t lo = end - cap; if (lo < start) lo = start;
    int64_t hi = start + frames; if (hi > end) hi = end;
    for (int64_t t = lo; t < hi; t++) {
        const float *s = r->samples + (size_t)(t % cap) * ch;
        memcpy(dst + (size_t)(t - start) * ch, s, ch * sizeof(float));
    }
}

#endif
