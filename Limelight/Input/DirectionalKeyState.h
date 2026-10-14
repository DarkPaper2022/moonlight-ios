#pragma once

#include <stdbool.h>
#include <stdint.h>

// Independent Win32 VK directions permit simultaneous holds (e.g. diagonals).
typedef struct {
    uint8_t pressedMask;
} DirectionalKeyState;

typedef struct {
    uint16_t keyUp;
    uint16_t keyDown;
} DirectionalKeyTransition;

static inline uint8_t DirectionalKeyMask(uint16_t key) {
    return key >= 0x25 && key <= 0x28 ? (uint8_t)(1u << (key - 0x25)) : 0;
}

static inline bool DirectionalKeyIsPressed(const DirectionalKeyState* state, uint16_t key) {
    return (state->pressedMask & DirectionalKeyMask(key)) != 0;
}

static inline DirectionalKeyTransition DirectionalKeySetPressed(DirectionalKeyState* state,
                                                                uint16_t key, bool pressed) {
    DirectionalKeyTransition transition = {0, 0};
    uint8_t mask = DirectionalKeyMask(key);
    if (mask && DirectionalKeyIsPressed(state, key) != pressed) {
        if (pressed) {
            state->pressedMask |= mask;
            transition.keyDown = key;
        } else {
            state->pressedMask &= (uint8_t)~mask;
            transition.keyUp = key;
        }
    }
    return transition;
}
