#include <assert.h>
#include <stdio.h>

#include "../Limelight/Input/DirectionalKeyState.h"

static void expect_transition(DirectionalKeyState* state, uint16_t next,
                              uint16_t expected_up, uint16_t expected_down) {
    DirectionalKeyTransition transition = DirectionalKeySetHeldKey(state, next);
    assert(transition.keyUp == expected_up);
    assert(transition.keyDown == expected_down);
    assert(state->heldKey == next);
}

int main(void) {
    DirectionalKeyState state = {0};

    // Touch jitter is neutral; selecting a direction emits only one key-down.
    assert(DirectionalKeyForOffset(0, 0) == 0);
    assert(DirectionalKeyForOffset(9.99f, -9.99f) == 0);
    expect_transition(&state, DirectionalKeyForOffset(1, -20), 0, 0x26);
    for (int i = 0; i < 1000; i++) {
        expect_transition(&state, DirectionalKeyForOffset(2, -40), 0, 0);
    }

    // Switching directions must include the old key-up and new key-down.
    expect_transition(&state, DirectionalKeyForOffset(30, -15), 0x26, 0x27);
    expect_transition(&state, DirectionalKeyForOffset(-35, 4), 0x27, 0x25);
    expect_transition(&state, DirectionalKeyForOffset(-10, 50), 0x25, 0x28);

    // Returning to the touch origin releases the key, then permits another hold.
    expect_transition(&state, DirectionalKeyForOffset(2, 3), 0x28, 0);
    expect_transition(&state, DirectionalKeyForOffset(0, -10), 0, 0x26);

    // Lift, cancellation, rotation and keyboard dismissal all use this reset.
    expect_transition(&state, 0, 0x26, 0);
    expect_transition(&state, 0, 0, 0);
    const uint16_t directions[] = {0x25, 0x26, 0x27, 0x28};
    for (unsigned i = 0; i < sizeof(directions) / sizeof(directions[0]); i++) {
        expect_transition(&state, directions[i], 0, directions[i]);
        expect_transition(&state, 0, directions[i], 0);
        expect_transition(&state, 0, 0, 0);
    }

    // Large drags outside the bar still choose a direction; diagonals pick one.
    assert(DirectionalKeyForOffset(-1000, -20) == 0x25);
    assert(DirectionalKeyForOffset(1000, 20) == 0x27);
    assert(DirectionalKeyForOffset(20, -1000) == 0x26);
    assert(DirectionalKeyForOffset(20, 1000) == 0x28);
    assert(DirectionalKeyForOffset(30, -30) == 0x26);
    puts("PASS: four directions, sustained hold, direction change, neutral zone, release and repeated cancellation");
    return 0;
}
