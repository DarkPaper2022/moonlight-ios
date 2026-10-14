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
    // Real report: 1668x2388 portrait encoding, 2560x1440 host desktop.
    // Sunshine fits the desktop inside the entire portrait bitstream first.
    const double desktopAspect = 2560.0 / 1440.0;
    StreamVideoSize oldContent = StreamVideoSizeForViewport(1668, 2388, desktopAspect);
    assert(oldContent.width == 1668 && oldContent.height == 938.25);
    double oldStretchedHeight = oldContent.height * 1194.0 / 2388.0;
    assert(oldStretchedHeight == 469.125);
    assert(oldContent.width / oldStretchedHeight == desktopAspect * 2.0);

    // Aspect fit alone still shrinks the portrait encoded canvas to half width.
    StreamVideoSize oldClient = StreamVideoSizeForViewport(1668, 1194, 1668.0 / 2388.0);
    assert(oldClient.width == 834 && oldClient.height == 1194);

    // Negotiate from actual upper viewport points at 2x screen scale instead.
    StreamPixelSize native = StreamNativePixelsForViewport(834, 597, 2);
    assert(native.width == 1668 && native.height == 1194);
    StreamVideoSize newContent = StreamVideoSizeForViewport(native.width, native.height, desktopAspect);
    StreamVideoSize newClient = StreamVideoSizeForViewport(1668, 1194, (double)native.width / native.height);
    assert(newClient.width == 1668 && newClient.height == 1194);
    assert(newContent.width == 1668 && newContent.height == 938.25);
    assert(newContent.width / newContent.height == desktopAspect);
    assert(newContent.height == oldStretchedHeight * 2.0);

    assert(StreamResolutionIsLegacyPortraitNative(1668, 2388, 1668, 2388));
    assert(StreamResolutionIsLegacyPortraitNative(1668, 2388, 2388, 1668));
    assert(!StreamResolutionIsLegacyPortraitNative(1920, 1080, 1668, 2388));
    assert(!StreamResolutionIsLegacyPortraitNative(900, 1600, 1668, 2388));
    native = StreamNativePixelsForViewport(500, 350, 2);
    assert(native.width == 1000 && native.height == 700);
    native = StreamNativePixelsForViewport(833.9, 588.7, 2);
    assert(native.width == 1666 && native.height == 1176);
    native = StreamNativePixelsForViewport(6000, 5000, 2);
    assert(native.width == 8192 && native.height == 8192);
    native = StreamNativePixelsForViewport(0, 500, 2);
    assert(native.width == 0 && native.height == 0);
    StreamVideoSize fit = StreamVideoSizeForViewport(1920, 1080, desktopAspect);
    assert(fit.width == 1920 && fit.height == 1080);
    fit = StreamVideoSizeForViewport(1000, 400, desktopAspect);
    assert(fit.height == 400 && fit.width < 1000);
    puts("PASS: denied rotation retains selected layout; toggling, resizing and stale errors");
    puts("PASS: reproduce 1668x2388 double letterboxing; viewport-native encoding restores size without stretching");
    puts("PASS: legacy native migration, other fixed/custom sizes, view scaling and even encoder dimensions");
    return 0;
}
