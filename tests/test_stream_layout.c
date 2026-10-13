#include <assert.h>
#include <stdio.h>

#include "../Limelight/Input/StreamLayoutState.h"
#include "../Limelight/Input/StreamVideoGeometry.h"

int main(void) {
    StreamLayoutState state = {0};
    assert(!StreamLayoutUsesKeyboard(&state, 1180, 820));
    assert(StreamLayoutUsesKeyboard(&state, 820, 1180));

    // A landscape window rejects programmatic rotation. The button must still
    // enter keyboard layout, including during later layout/resize callbacks.
    assert(StreamLayoutToggle(&state, 1180, 820));
    uint64_t firstRequest = state.requestNumber;
    StreamLayoutSceneRequestRejected(&state, firstRequest);
    assert(state.sceneRotationUnavailable);
    assert(!StreamLayoutRotatesVideo(&state, 820, 1180));
    assert(StreamLayoutUsesKeyboard(&state, 1180, 820));
    assert(StreamLayoutUsesKeyboard(&state, 820, 1180));
    assert(StreamLayoutUsesKeyboard(&state, 500, 700));

    // Another button press leaves keyboard layout even in a portrait window.
    assert(!StreamLayoutToggle(&state, 820, 1180));
    assert(!StreamLayoutUsesKeyboard(&state, 820, 1180));
    assert(!StreamLayoutUsesKeyboard(&state, 1180, 820));
    assert(state.sceneRotationUnavailable);
    assert(StreamLayoutRotatesVideo(&state, 820, 1180));
    assert(!StreamLayoutRotatesVideo(&state, 1180, 820));

    StreamLayoutState fresh = {0};
    assert(StreamLayoutToggle(&fresh, 1180, 820));
    uint64_t oldRequest = fresh.requestNumber;
    assert(!StreamLayoutToggle(&fresh, 1180, 820));
    StreamLayoutSceneRequestRejected(&fresh, oldRequest);
    assert(!fresh.sceneRotationUnavailable);
    assert(fresh.mode == StreamLayoutFullscreen);
    assert(!StreamLayoutRotatesVideo(&fresh, 820, 1180));
    // Reproduce a wide desktop looking half-height in the upper viewport.
    // Keyboard mode must use the whole viewport, including after resize.
    StreamVideoSize fit = StreamVideoSizeForViewport(820, 573, 32.0 / 9.0, false);
    assert(fit.width == 820 && fit.height < 573 / 2.0);
    StreamVideoSize fill = StreamVideoSizeForViewport(820, 573, 32.0 / 9.0, true);
    assert(fill.width == 820 && fill.height == 573);
    fill = StreamVideoSizeForViewport(500, 350, 16.0 / 9.0, true);
    assert(fill.width == 500 && fill.height == 350);
    fit = StreamVideoSizeForViewport(1920, 1080, 16.0 / 9.0, false);
    assert(fit.width == 1920 && fit.height == 1080);
    fit = StreamVideoSizeForViewport(1000, 400, 16.0 / 9.0, false);
    assert(fit.height == 400 && fit.width < 1000);
    StreamVideoSize empty = StreamVideoSizeForViewport(0, 400, 16.0 / 9.0, true);
    assert(empty.width == 0 && empty.height == 0);
    puts("PASS: denied rotation retains selected layout; toggling, resizing and stale errors");
    puts("PASS: keyboard video fills entire viewport; full-screen aspect fit and empty bounds");
    return 0;
}
