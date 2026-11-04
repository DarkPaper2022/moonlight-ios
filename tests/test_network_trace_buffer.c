#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include "../Limelight/Stream/NetworkTraceBuffer.h"

static MLNetworkTraceBuffer buffer;
static unsigned finished;
static void* produce(void* context) {
    uint32_t producer = (uint32_t)(uintptr_t)context;
    for (uint32_t i = 0; i < 200000; i++) {
        LI_NETWORK_TRACE_EVENT event = {.timeUs=i, .value=i, .aux=producer, .kind=1, .stream=1};
        MLNetworkTraceBufferPush(&buffer, &event);
    }
    __atomic_add_fetch(&finished, 1, __ATOMIC_RELEASE);
    return NULL;
}

int main(void) {
    assert(sizeof(LI_NETWORK_TRACE_EVENT) == 32);
    assert(MLNetworkTraceBufferInit(&buffer, 16));
    LI_NETWORK_TRACE_EVENT event = {.kind=1, .stream=1};
    for (int i = 0; i < 16; i++) assert(MLNetworkTraceBufferPush(&buffer, &event));
    assert(!MLNetworkTraceBufferPush(&buffer, &event));
    pthread_mutex_lock(&buffer.mutex);
    assert(!MLNetworkTraceBufferPush(&buffer, &event));
    pthread_mutex_unlock(&buffer.mutex);
    assert(MLNetworkTraceBufferDropped(&buffer) == 2);
    uint32_t count;
    MLNetworkTraceBufferTake(&buffer, &count);
    assert(count == 16);
    MLNetworkTraceBufferDestroy(&buffer);
    assert(MLNetworkTraceBufferInit(&buffer, 4096));
    pthread_t threads[3];
    for (uintptr_t i = 0; i < 3; i++) assert(pthread_create(&threads[i], NULL, produce, (void*)i) == 0);
    uint64_t stored = 0;
    do {
        const LI_NETWORK_TRACE_EVENT* records = MLNetworkTraceBufferTake(&buffer, &count);
        for (uint32_t i = 0; i < count; i++) {
            assert(records[i].timeUs == records[i].value);
            assert(records[i].aux < 3 && records[i].kind == 1 && records[i].stream == 1);
        }
        stored += count;
    } while (__atomic_load_n(&finished, __ATOMIC_ACQUIRE) != 3);
    for (int i = 0; i < 3; i++) pthread_join(threads[i], NULL);
    MLNetworkTraceBufferTake(&buffer, &count);
    stored += count;
    assert(stored + MLNetworkTraceBufferDropped(&buffer) == 600000);
    printf("Trace: stored=%llu, explicitly dropped=%llu, total=600000\n",
           (unsigned long long)stored, (unsigned long long)MLNetworkTraceBufferDropped(&buffer));
    MLNetworkTraceBufferDestroy(&buffer);
    return 0;
}
