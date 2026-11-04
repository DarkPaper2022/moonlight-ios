#pragma once

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include "Limelight.h"

typedef struct {
    pthread_mutex_t mutex;
    LI_NETWORK_TRACE_EVENT* buffers[2];
    uint32_t capacity;
    uint32_t count;
    unsigned active;
    uint64_t dropped;
} MLNetworkTraceBuffer;

static inline bool MLNetworkTraceBufferInit(MLNetworkTraceBuffer* buffer, uint32_t capacity) {
    buffer->capacity = capacity;
    buffer->count = buffer->active = 0;
    buffer->dropped = 0;
    buffer->buffers[0] = calloc(capacity, sizeof(LI_NETWORK_TRACE_EVENT));
    buffer->buffers[1] = calloc(capacity, sizeof(LI_NETWORK_TRACE_EVENT));
    if (!buffer->buffers[0] || !buffer->buffers[1]) {
        free(buffer->buffers[0]); free(buffer->buffers[1]);
        return false;
    }
    if (pthread_mutex_init(&buffer->mutex, NULL) != 0) {
        free(buffer->buffers[0]); free(buffer->buffers[1]);
        return false;
    }
    return true;
}

// The receive/playout threads never wait for logging, storage or upload.
static inline bool MLNetworkTraceBufferPush(MLNetworkTraceBuffer* buffer, const LI_NETWORK_TRACE_EVENT* event) {
    if (pthread_mutex_trylock(&buffer->mutex) != 0) {
        __atomic_add_fetch(&buffer->dropped, 1, __ATOMIC_RELAXED);
        return false;
    }
    bool stored = buffer->count < buffer->capacity;
    if (stored) buffer->buffers[buffer->active][buffer->count++] = *event;
    pthread_mutex_unlock(&buffer->mutex);
    if (!stored) __atomic_add_fetch(&buffer->dropped, 1, __ATOMIC_RELAXED);
    return stored;
}

// One serial consumer copies this returned buffer before calling Take again.
// Swapping pointers keeps producer lock hold time independent of batch size.
static inline const LI_NETWORK_TRACE_EVENT* MLNetworkTraceBufferTake(MLNetworkTraceBuffer* buffer, uint32_t* count) {
    pthread_mutex_lock(&buffer->mutex);
    const LI_NETWORK_TRACE_EVENT* records = buffer->buffers[buffer->active];
    *count = buffer->count;
    buffer->active ^= 1;
    buffer->count = 0;
    pthread_mutex_unlock(&buffer->mutex);
    return records;
}

static inline uint64_t MLNetworkTraceBufferDropped(MLNetworkTraceBuffer* buffer) {
    return __atomic_load_n(&buffer->dropped, __ATOMIC_RELAXED);
}

static inline void MLNetworkTraceBufferDestroy(MLNetworkTraceBuffer* buffer) {
    free(buffer->buffers[0]); free(buffer->buffers[1]);
    pthread_mutex_destroy(&buffer->mutex);
}
