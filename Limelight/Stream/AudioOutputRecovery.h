#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// Only the decoder thread owns this state/device. Notification handlers merely
// request recovery atomically; they never close SDL from a system callback.
typedef struct {
    void* context;
    bool (*restart)(void* context);
    uint32_t (*queuedBytes)(void* context);
    bool (*playing)(void* context);
    int (*queue)(void* context, const void* data, uint32_t bytes);
    void (*clear)(void* context);
    void (*pause)(void* context, bool paused);
} AudioOutputOperations;

typedef struct {
    bool started;
    bool recoveryPending;
    uint32_t cushionBytes;
    uint32_t limitBytes;
    uint32_t lastQueuedBytes;
    uint64_t lastDrainMs;
    uint64_t nextRetryMs;
    uint64_t recoveries;
    uint64_t droppedFrames;
} AudioOutputRecovery;

static inline void AudioOutputRecoveryInit(AudioOutputRecovery* state,
                                           uint32_t cushionBytes, uint32_t limitBytes) {
    memset(state, 0, sizeof(*state));
    state->cushionBytes = cushionBytes;
    state->limitBytes = limitBytes < cushionBytes ? cushionBytes : limitBytes;
}

// Never wait for a device to drain: a suspended/broken output used to trap the
// audio decoder indefinitely in its backpressure loop. Drop bounded excess PCM
// and recreate only the output device when no drain is observed for 250ms.
// Return 1 if queued, 0 if intentionally skipped, -1 if a device operation failed.
static inline int AudioOutputSubmit(AudioOutputRecovery* state, const AudioOutputOperations* ops,
                                    const void* data, uint32_t bytes, uint64_t nowMs,
                                    bool interrupted, bool requestRecovery) {
    if (requestRecovery) state->recoveryPending = true;
    if (interrupted) {
        if (state->started || state->lastQueuedBytes) {
            ops->pause(ops->context, true);
            ops->clear(ops->context);
        }
        state->started = false;
        state->lastQueuedBytes = 0;
        state->recoveryPending = true;
        return 0;
    }

    uint32_t queued = ops->queuedBytes(ops->context);
    if (state->started) {
        if (queued < state->lastQueuedBytes) state->lastDrainMs = nowMs;
        if (!ops->playing(ops->context) || nowMs - state->lastDrainMs >= 250) {
            state->recoveryPending = true;
        }
    }
    if (state->recoveryPending) {
        if (nowMs < state->nextRetryMs) return 0;
        state->nextRetryMs = nowMs + 1000;
        state->started = false;
        state->lastQueuedBytes = 0;
        if (!ops->restart(ops->context)) return -1;
        state->recoveryPending = false;
        state->lastDrainMs = nowMs;
        state->recoveries++;
        queued = 0;
    }
    if (bytes > state->limitBytes || queued > state->limitBytes - bytes) {
        state->droppedFrames++;
        return 0;
    }
    if (ops->queue(ops->context, data, bytes) < 0) {
        state->recoveryPending = true;
        return -1;
    }
    state->lastQueuedBytes = ops->queuedBytes(ops->context);
    if (!state->started && state->lastQueuedBytes >= state->cushionBytes) {
        ops->pause(ops->context, false);
        state->started = true;
        state->lastDrainMs = nowMs;
    }
    return 1;
}
