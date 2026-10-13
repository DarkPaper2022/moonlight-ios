#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    StreamLayoutAutomatic,
    StreamLayoutFullscreen,
    StreamLayoutKeyboard
} StreamLayoutMode;

typedef struct {
    StreamLayoutMode mode;
    bool sceneRotationUnavailable;
    uint64_t requestNumber;
} StreamLayoutState;

static inline bool StreamLayoutUsesKeyboard(const StreamLayoutState* state,
                                            double width, double height) {
    return state->mode == StreamLayoutAutomatic ? height > width :
           state->mode == StreamLayoutKeyboard;
}

static inline bool StreamLayoutToggle(StreamLayoutState* state, double width, double height) {
    bool keyboard = !StreamLayoutUsesKeyboard(state, width, height);
    state->mode = keyboard ? StreamLayoutKeyboard : StreamLayoutFullscreen;
    state->requestNumber++;
    return keyboard;
}

static inline void StreamLayoutSceneRequestRejected(StreamLayoutState* state, uint64_t requestNumber) {
    // A stale async error must not undo a newer button press.
    if (requestNumber == state->requestNumber) {
        state->sceneRotationUnavailable = true;
    }
    // The selected in-app layout survives the denied OS request.
}

static inline bool StreamLayoutRotatesVideo(const StreamLayoutState* state,
                                            double width, double height) {
    // A portrait host window can forbid scene rotation. Rotate the full-screen
    // video/input surface locally so the device can still be used sideways.
    return state->sceneRotationUnavailable && state->mode == StreamLayoutFullscreen && height > width;
}
