#include "../MSLoopbackRing.h"
#include <stdio.h>
#include <math.h>

static int failures = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); failures++; } } while (0)

static void fill(float *b, uint32_t frames, float base) {
    for (uint32_t i = 0; i < frames; i++) { b[2*i] = base + i; b[2*i+1] = -(base + i); }
}

int main(void) {
    float store[8 * 2];
    MSLoopbackRing r;
    ms_ring_init(&r, store, 8, 2);
    float in[6 * 2], out[6 * 2];

    // simple write/read
    fill(in, 4, 1);
    ms_ring_write(&r, 0, 4, in, 1.0f);
    ms_ring_read(&r, 0, 4, out);
    CHECK(out[0] == 1 && out[6] == 4 && out[7] == -4);
    // beyond end is silence
    ms_ring_read(&r, 2, 6, out);
    CHECK(out[0] == 3 && out[2] == 4 && out[4] == 0 && out[10] == 0);

    // wrap-around: capacity 8, write 6 at t=6 -> slots 6,7,0,1,2,3
    fill(in, 6, 10);
    ms_ring_write(&r, 6, 6, in, 1.0f);
    ms_ring_read(&r, 6, 6, out);
    for (int i = 0; i < 6; i++) CHECK(out[2*i] == 10 + i && out[2*i+1] == -(10 + i));
    // older frames than end-capacity (end=12, lo=4): t=2..3 silent, t=4,5 are gap zeros
    ms_ring_read(&r, 2, 6, out);
    CHECK(out[0] == 0 && out[2] == 0 && out[4] == 0 && out[6] == 0 && out[8] == 10);

    // gain
    ms_ring_reset(&r);
    fill(in, 3, 2);
    ms_ring_write(&r, 0, 3, in, 0.5f);
    ms_ring_read(&r, 0, 3, out);
    CHECK(fabsf(out[0] - 1.0f) < 1e-6f && fabsf(out[4] - 2.0f) < 1e-6f);
    ms_ring_write(&r, 3, 3, in, 0.0f);   // mute
    ms_ring_read(&r, 3, 3, out);
    CHECK(out[0] == 0 && out[4] == 0);

    // gap becomes silence even over stale data
    ms_ring_reset(&r);
    fill(in, 6, 100);
    ms_ring_write(&r, 0, 6, in, 1.0f);
    ms_ring_write(&r, 12, 2, in, 1.0f);   // gap 6..11 (cap 8 -> zero 6..11)
    ms_ring_read(&r, 6, 6, out);
    for (int i = 0; i < 12; i++) CHECK(out[i] == 0);
    ms_ring_read(&r, 12, 2, out);
    CHECK(out[0] == 100 && out[2] == 101);

    // oversize write keeps newest frames
    ms_ring_reset(&r);
    float big[12 * 2];
    fill(big, 12, 0);
    ms_ring_write(&r, 0, 12, big, 1.0f);
    ms_ring_read(&r, 4, 8, big);
    CHECK(big[0] == 4 && big[14] == 11);

    // reset clears everything
    ms_ring_reset(&r);
    ms_ring_read(&r, 0, 6, out);
    CHECK(out[0] == 0 && out[10] == 0);

    printf(failures ? "ring_test: %d failure(s)\n" : "ring_test: ok\n", failures);
    return failures ? 1 : 0;
}
