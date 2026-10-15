// The sound apps play to Ensemble's sound device, shared by the device (Driver/EnsembleDevice.c, run by
// coreaudiod) with the Ensemble app through POSIX shared memory. The app reads it without an input
// stream, so macOS shows no microphone indicator. One layout for both sides.
//
// The device's clock is the host clock: while its IO runs, device sample time t is presented at host
// time epoch + t * hostTicksPerFrame. The device writes each frame, then its sample time + 1 as the
// frame's stamp; a read gives a frame only while the stamp matches the sample time asked for, so it
// never gives a frame from an earlier lap or one not written yet (silence instead).
#ifndef SHARED_SOUND_H
#define SHARED_SOUND_H

#include <fcntl.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define SHARED_SOUND_FRAMES 16384
#define SHARED_SOUND_CHANNELS 2

typedef struct {
    double hostTicksPerFrame;   // set before the device shares the memory's name
    _Atomic uint64_t epoch;     // host time of sample time 0 since the device's IO last started
    _Atomic uint64_t stamp[SHARED_SOUND_FRAMES];
    float sound[SHARED_SOUND_FRAMES * SHARED_SOUND_CHANNELS];
} SharedSound;

/// Device side, before its IO starts (no write runs): forgets every frame and starts the clock at `epoch`.
static inline void SharedSoundRestart(SharedSound *s, uint64_t epoch) {
    for (uint32_t i = 0; i < SHARED_SOUND_FRAMES; i++) atomic_store_explicit(&s->stamp[i], 0, memory_order_relaxed);
    atomic_store_explicit(&s->epoch, epoch, memory_order_release);
}

/// Device side: stores the frame of sample time `time`.
static inline void SharedSoundWrite(SharedSound *s, uint64_t time, const float *frame) {
    uint32_t at = (uint32_t)(time % SHARED_SOUND_FRAMES);
    atomic_store_explicit(&s->stamp[at], 0, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    memcpy(s->sound + at * SHARED_SOUND_CHANNELS, frame, SHARED_SOUND_CHANNELS * sizeof(float));
    atomic_store_explicit(&s->stamp[at], time + 1, memory_order_release);
}

/// App side: maps the memory named `name` read only; NULL if it cannot. Undo with SharedSoundUnmap.
static inline const SharedSound *SharedSoundMap(const char *name) {
    int fd = shm_open(name, O_RDONLY);
    if (fd < 0) return NULL;
    void *memory = mmap(NULL, sizeof(SharedSound), PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    return memory == MAP_FAILED ? NULL : memory;
}

static inline void SharedSoundUnmap(const SharedSound *s) { munmap((void *)s, sizeof(SharedSound)); }

/// App side: the device's sample time (fractional) presented at host time `hostTime`.
static inline double SharedSoundSampleTime(const SharedSound *s, uint64_t hostTime) {
    uint64_t epoch = atomic_load_explicit((_Atomic uint64_t *)&s->epoch, memory_order_acquire);
    return ((double)hostTime - (double)epoch) / s->hostTicksPerFrame;
}

/// App side: copies the frames of sample times [first, first + count) into `out` (interleaved stereo),
/// silence where a frame is not there. Returns how many were not there.
static inline int SharedSoundRead(const SharedSound *s, int64_t first, int count, float *out) {
    int missing = 0;
    for (int i = 0; i < count; i++) {
        int64_t time = first + i;
        float *own = out + i * SHARED_SOUND_CHANNELS;
        bool ok = false;
        if (time >= 0) {
            uint32_t at = (uint32_t)(time % SHARED_SOUND_FRAMES);
            _Atomic uint64_t *stamp = (_Atomic uint64_t *)&s->stamp[at];
            ok = atomic_load_explicit(stamp, memory_order_acquire) == (uint64_t)time + 1;
            if (ok) memcpy(own, s->sound + at * SHARED_SOUND_CHANNELS, SHARED_SOUND_CHANNELS * sizeof(float));
            atomic_thread_fence(memory_order_acquire);
            ok = ok && atomic_load_explicit(stamp, memory_order_relaxed) == (uint64_t)time + 1;
        }
        if (!ok) { memset(own, 0, SHARED_SOUND_CHANNELS * sizeof(float)); missing++; }
    }
    return missing;
}

#endif
