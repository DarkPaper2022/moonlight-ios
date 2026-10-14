#include <assert.h>
#include <stdio.h>
#include "../Limelight/Input/DirectionalKeyState.h"

static void expect(DirectionalKeyState* state, uint16_t key, bool pressed,
                   uint16_t up, uint16_t down) {
    DirectionalKeyTransition change = DirectionalKeySetPressed(state, key, pressed);
    assert(change.keyUp == up && change.keyDown == down);
    assert(DirectionalKeyIsPressed(state, key) == pressed);
}

int main(void) {
    DirectionalKeyState state = {0};
    for (uint16_t key = 0x25; key <= 0x28; key++) {
        expect(&state, key, true, 0, key);
        for (int i = 0; i < 1000; i++) expect(&state, key, true, 0, 0);
        expect(&state, key, false, key, 0);
        expect(&state, key, false, 0, 0);
    }
    // Two-finger diagonal: releasing one button must leave the other held.
    expect(&state, 0x25, true, 0, 0x25);
    expect(&state, 0x26, true, 0, 0x26);
    expect(&state, 0x25, false, 0x25, 0);
    assert(DirectionalKeyIsPressed(&state, 0x26));
    expect(&state, 0x26, false, 0x26, 0);
    // Dismiss/rotation/background release all, once only.
    for (uint16_t key = 0x25; key <= 0x28; key++) expect(&state, key, true, 0, key);
    for (uint16_t key = 0x25; key <= 0x28; key++) expect(&state, key, false, key, 0);
    for (uint16_t key = 0x25; key <= 0x28; key++) expect(&state, key, false, 0, 0);
    assert(state.pressedMask == 0);
    DirectionalKeyTransition invalid = DirectionalKeySetPressed(&state, 0x24, true);
    assert(!invalid.keyUp && !invalid.keyDown && !state.pressedMask);
    puts("PASS: four buttons, sustained holds, independent diagonal keys and idempotent release");
    return 0;
}
