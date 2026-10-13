#pragma once

#include <math.h>
#include <stdint.h>

// Win32 VK codes, as used by the GameStream keyboard protocol.
typedef struct {
    uint16_t heldKey;
} DirectionalKeyState;

typedef struct {
    uint16_t keyUp;
    uint16_t keyDown;
} DirectionalKeyTransition;

static inline uint16_t DirectionalKeyForOffset(float x, float y) {
    // A neutral zone lets the user release a direction without lifting.
    if (fabsf(x) < 10.0f && fabsf(y) < 10.0f) {
        return 0;
    }
    if (fabsf(x) > fabsf(y)) {
        return x < 0 ? 0x25 : 0x27;
    }
    return y < 0 ? 0x26 : 0x28;
}

static inline DirectionalKeyTransition DirectionalKeySetHeldKey(DirectionalKeyState* state,
                                                                 uint16_t key) {
    DirectionalKeyTransition transition = {0, 0};
    if (state->heldKey != key) {
        transition.keyUp = state->heldKey;
        transition.keyDown = key;
        state->heldKey = key;
    }
    return transition;
}
