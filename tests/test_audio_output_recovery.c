#include <assert.h>
#include <stdio.h>
#include "../Limelight/Stream/AudioOutputRecovery.h"

typedef struct {
    uint32_t bytes;
    bool playing;
    int restarts;
    int failures;
    int clears;
    bool failQueue;
} FakeDevice;

static bool restart(void* context) {
    FakeDevice* device = context;
    device->restarts++;
    device->bytes = 0;
    device->playing = false;
    if (device->failures) { device->failures--; return false; }
    return true;
}
static uint32_t queued(void* context) { return ((FakeDevice*)context)->bytes; }
static bool playing(void* context) { return ((FakeDevice*)context)->playing; }
static int queue(void* context, const void* data, uint32_t bytes) {
    FakeDevice* device = context;
    (void)data;
    if (device->failQueue) { device->failQueue = false; return -1; }
    device->bytes += bytes;
    return 0;
}
static void clear(void* context) {
    FakeDevice* device = context;
    device->bytes = 0;
    device->clears++;
}
static void pause(void* context, bool paused) { ((FakeDevice*)context)->playing = !paused; }

static const uint32_t frameBytes = 960;
static int submit(AudioOutputRecovery* state, AudioOutputOperations* ops, uint64_t ms,
                  bool interrupted, bool repair) {
    int result = AudioOutputSubmit(state, ops, "unused", frameBytes, ms, interrupted, repair);
    assert(queued(ops->context) <= state->limitBytes);
    return result;
}
static void consume(FakeDevice* device) {
    if (device->playing && device->bytes >= frameBytes) device->bytes -= frameBytes;
}

int main(void) {
    FakeDevice device = {0};
    AudioOutputOperations ops = {&device, restart, queued, playing, queue, clear, pause};
    AudioOutputRecovery state;
    AudioOutputRecoveryInit(&state, 4 * frameBytes, 35 * frameBytes);
    for (uint64_t ms = 0; ms < 10000; ms += 5) {
        consume(&device);
        assert(submit(&state, &ops, ms, false, false) == 1);
    }
    assert(state.started && !state.recoveries && !state.droppedFrames);

    // CoreAudio may stop draining while SDL still claims PLAYING. The old
    // decoder never returns once this queue reaches its high-water mark.
    for (uint64_t ms = 10000; ms < 10300; ms += 5) submit(&state, &ops, ms, false, false);
    assert(device.restarts == 1 && state.recoveries == 1 && state.droppedFrames);
    for (uint64_t ms = 10300; ms < 12000; ms += 5) {
        consume(&device);
        submit(&state, &ops, ms, false, false);
    }
    assert(device.playing && device.restarts == 1);

    // Genuine interruptions may last arbitrarily long. Do not reactivate or
    // accumulate stale PCM until the interruption has ended.
    for (uint64_t ms = 12000; ms < 20000; ms += 5) submit(&state, &ops, ms, true, false);
    assert(!device.playing && !device.bytes && device.restarts == 1 && device.clears == 1);
    submit(&state, &ops, 20000, false, true);
    assert(device.restarts == 2);
    for (uint64_t ms = 20005; ms < 22000; ms += 5) {
        consume(&device);
        submit(&state, &ops, ms, false, false);
    }
    assert(device.playing);

    // Reopen failures are bounded, retried once per second, and need no video
    // reconnect. A successful restart prebuffers fresh audio before unpausing.
    device.failures = 2;
    int before = device.restarts;
    submit(&state, &ops, 22000, false, true);
    for (uint64_t ms = 22005; ms < 24000; ms += 5) submit(&state, &ops, ms, false, false);
    assert(device.restarts == before + 2 && state.recoveryPending);
    submit(&state, &ops, 24000, false, false);
    assert(device.restarts == before + 3 && !state.recoveryPending && !state.started);
    for (uint64_t ms = 24005; ms < 26000; ms += 5) {
        consume(&device);
        submit(&state, &ops, ms, false, false);
    }
    assert(device.playing);
    device.failQueue = true;
    assert(submit(&state, &ops, 26000, false, false) == -1);
    assert(state.recoveryPending);
    submit(&state, &ops, 26005, false, false);
    assert(!state.recoveryPending);

    AudioOutputRecoveryInit(&state, 4 * frameBytes, frameBytes);
    assert(state.limitBytes == 4 * frameBytes);
    puts("PASS: healthy drain, frozen PLAYING device, bounded queue, interruptions, retry cooldown and queue failure recovery");
    return 0;
}
