# Portrait streaming and directional keyboard control

Version: 9.0.16. Base: `v9.0.11-audiodelay` (`0cd848e`).
The common-c gitlink remains `19d67932d77b5c86c7553b91b0294081573c60e2`;
this feature does not change the 9.0.11 audio implementation or host configuration.

## Usage

- During a connected iOS stream, tap the rotation button in the upper-right
  corner, or the rotation button on the keyboard bar, to switch orientation.
- Portrait reserves the upper half of the safe area for the video and the lower
  half for keyboard input. The system keyboard opens automatically. Video is
  aspect-fit without stretching. Native resolution reserves the full landscape
  window pixel budget when connecting, even when starting in portrait.
  Absolute touch and mouse coordinates use the same video geometry.
- The keyboard button shows or hides the keyboard in either orientation. The
  existing three-finger gesture and Done button still work. Switching back to
  landscape hides the keyboard and restores the full-screen stream.
- Hold one of the four `← ↑ ↓ →` buttons to keep that keyboard arrow down.
  Lift, drag outside the button or cancel to release it; drag back inside to
  press again. Two buttons can be held simultaneously for a diagonal.
- Direction input sends keyboard DOWN/UP events, including modifier flags for
  latched Shift/Ctrl/Alt/Windows keys. Sunshine handles keyboard autorepeat;
  the client does not synthesize repeated taps or gamepad directions.
- The four arrow buttons and rotation button remain visible on narrow screens;
  the special-key row scrolls horizontally independently of the direction control.
- Rotation, keyboard dismissal, application inactivity and stream exit release
  held toolbar keys. Viewport changes reset absolute-mode zoom to fit.

## Layout and platform details

The portrait video viewport is half of the safe area. Native/Native Safe Area
reserve a landscape encoded canvas from the laid-out full window: longer side
as width, shorter side as height, multiplied by the window's screen scale and
rounded down to even dimensions. Safe Area subtracts the current safe insets.
This reserves the same full-resolution pixels for either starting orientation
and avoids enlarging a low-resolution upper-half stream when switching to
landscape. It also avoids the old full-portrait server padding: portrait only
scales the landscape frame uniformly to its upper viewport. This uses more
encoder/decoder pixels than the 9.0.15 half-screen request; bitrate stays as
configured. Fixed/custom resolutions remain fixed. A legacy full-portrait
native profile is still migrated automatically. Reconnect after updating.

The video stream starts after viewport layout, so renderer and input mapping
receive the final negotiated dimensions before any network launch/resume.

The portrait video viewport is half of the safe area. On small phones, it may
shrink further to avoid a docked keyboard taller than the lower half. System
keyboards retain their native height; an iPad floating keyboard is not forced
to dock, and a hardware keyboard may suppress the software keyboard.

The layout selection is independent of the host window's dimensions. iOS 16+
also tries Apple's
[window scene geometry request](https://developer.apple.com/documentation/uikit/uiwindowscene/requestgeometryupdate(_:errorhandler:)).
If the scene refuses programmatic rotation, the chosen layout stays active,
and subsequent button presses work locally without repeating the rejected
request or showing a blocking error dialog. In a portrait host window,
full-screen mode rotates the video and its input surface by 90 degrees so it
can be used sideways; keyboard mode restores the native upright split layout.
The keyboard itself remains the host's system keyboard. This does not rotate
or resize the LiveContainer/system window. iOS 15 uses
`attemptRotationToDeviceOrientation`; the local layout still changes even if
that call cannot rotate the scene. The keyboard avoidance constraint uses
[UIKeyboardLayoutGuide](https://developer.apple.com/documentation/uikit/uikeyboardlayoutguide).
The host's resolution, video encoder, and stream connection are unchanged by rotation.
The host selection screen keeps its landscape orientation policy. The new touch
control is compiled only into the iOS target.

## Verification records

### R1 — local direction-state and integration checks (2026-10-13)

Purpose: verify that a held direction produces one DOWN and remains held,
switching and cancellation release the old key, and the project keeps the
9.0.11 audio base.

Method, from the repository root:

```sh
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  tests/test_directional_key_state.c -o /tmp/moonlight-directional-key-test
/tmp/moonlight-directional-key-test
git diff --check
git diff v9.0.11-audiodelay -- moonlight-common/moonlight-common-c Limelight/Stream/Connection.m
```

Results: passed all four directions, 1,000 unchanged hold updates, direction
changes, dead-zone return, release, repeated cancellation and large drags.
No sanitizer errors. No whitespace errors. No audio integration or gitlink diff.
Python `plistlib` parsing verified portrait plus both landscape orientations
for iPhone/iPad. Project object IDs and the iOS Sources entry were also checked.

Conclusion: portable input state and local configuration checks pass. These
checks do not validate UIKit touch delivery, layout, rotation or device behavior.

### R2 — Apple build verification

Source commit: `e86621d465a94664b244bcd834d8e5200bb46e53`.
The development host is Linux without Xcode; the checks ran on macOS CI.

- [CI run 38390669429](https://github.com/DarkPaper2022/moonlight-ios/actions/runs/38390669429):
  iOS and tvOS Debug and Release simulator builds all succeeded. The direction
  transition test also passed with Apple clang.
- [IPA run 38390703503](https://github.com/DarkPaper2022/moonlight-ios/actions/runs/38390703503):
  unsigned iOS device Release build and IPA packaging succeeded.
- Downloaded companion-workspace artifact:
  `artifacts/Moonlight-PortraitKeyboard-v9.0.13.ipa`, 3,120,674 bytes.
  SHA-256: `5a376e09cde710b7c0342c3b6e76eac3eba26c7196caa299aef64f9c4b152456`.
- Verified ZIP integrity, internal version 9.0.13, iPhone/iPad portrait
  orientation declarations and the new direction control in the app binary.

Conclusion: both targets compile, and the unsigned iOS package is ready for
device acceptance. Runtime touch behavior, layout and rotation remain untested
on an iPad. No release tag, host deployment or software-source update was made.

### R3 — denied rotation and small portrait video regression (2026-10-14)

The user reported that the system refused programmatic rotation, and the video
occupied roughly half of the upper area. Version 9.0.13 reverted its orientation
policy and displayed an error on rejection; layout was still recomputed solely
from the unrotated window dimensions. The video also used aspect-fit inside the
already-halved viewport, leaving large bars for wide desktops.

Version 9.0.14 adds a persistent layout selection, ignores stale geometry-error
callbacks, and keeps local switching available after scene rejection. A local
90-degree transform rotates both video and input together in full-screen mode
in a portrait host window. Renderer creation, relayout, mouse/touch mapping and
pointer regions share one geometry calculation. Keyboard layout fills its
viewport; full-screen mode keeps normal aspect-fit.

Local command:

```sh
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  tests/test_stream_layout.c -o /tmp/moonlight-stream-layout-test
/tmp/moonlight-stream-layout-test
```

Passed: automatic layout, rejected rotation retaining keyboard layout,
subsequent switches and resizes, stale errors, local rotation only in the
restricted portrait full-screen case, wide-desktop reproduction, full-viewport
keyboard video sizing and unchanged full-screen aspect-fit. No sanitizer errors.
These are portable policy/geometry tests; they do not exercise live UIKit or
LiveContainer.

Apple verification for source `af1954b5c51b81d9168d66b2096f7a4bd33907f7`:

- [CI run 38441921601](https://github.com/DarkPaper2022/moonlight-ios/actions/runs/38441921601):
  iOS/tvOS Debug and Release simulator builds passed. The first iOS attempt
  failed during SDK setup with `Unable to connect to simulator` (exit 70);
  rerunning only the failed job succeeded. Both portable tests passed with
  Apple clang.
- [IPA run 38441951479](https://github.com/DarkPaper2022/moonlight-ios/actions/runs/38441951479):
  unsigned iOS device Release build and package upload succeeded.
- Package: `artifacts/Moonlight-PortraitKeyboard-v9.0.14.ipa` in the companion
  workspace, 3,121,379 bytes. SHA-256:
  `3b0da4253edba460902677907d1ae8134bb829c6393c0738fa1b8a1f477040ae`.
- Published in the companion `ipa-playground` Nginx directory and synchronized
  its config, source, homepage and cache. The live HTTPS source advertises
  9.0.14; homepage links match; complete IPA download matches size and SHA-256.
  The updater's `--check` reports the local 9.0.14 entry as current.

Conclusion: builds, regression tests and source publication pass. Actual
LiveContainer/iPad rotation, layout and touch alignment still need device
confirmation.

### R4 — screenshot and native encoder pixel budget (2026-10-14)

The user supplied a 1080x1546 portrait screenshot showing the desktop as a narrow
full-width band in the upper half, and requested no stretching. Read-only host
checks found capture output HDMI-A-1 at 2560x1440, while the active H.265 encoder
session was 1668x2388: the full portrait iPad native pixel grid. The short-lived
`nvidia-smi encodersessions` monitor was stopped by its confirmed PID; Sunshine
and display configuration were not changed.

This establishes the missing layer in R3's diagnosis: Sunshine first aspect-fits
the landscape desktop into the portrait encoded canvas, including black bands.
R3 then stretched the entire padded canvas into a half-height viewport. In ideal continuous geometry before encoder integer rounding, a
2560x1440 desktop occupies 1668x938.25 inside a 1668x2388 frame; scaling that whole
frame to 1668x1194 compresses desktop height to 469.125. Aspect-fit alone would
instead reduce its width to 834, still using only half the available width.

Version 9.0.15 restores aspect-fit and fixes native resolution at the source of
negotiation: layout first, then request pixels for the actual video viewport.
For an 834x597-point upper viewport at 2x scale, the encoder request becomes
1668x1194 and the same desktop occupies 1668x938.25 without distortion. Safe-area
insets can reduce the actual viewport; it is measured, not assumed. Native mode
is persisted separately from fixed dimensions, so future window changes and
reconnections use the current viewport. The settings preview follows the same
half-screen calculation. Renderer/input aspect ratio is refreshed before stream
launch. This does not modify the host monitor resolution.

The portable test now reproduces both failed fixes as negative controls and
asserts full-width desktop visibility with correct 16:9 proportions after
viewport-native negotiation. It also checks legacy migration, untouched ordinary
fixed/custom profiles, scaling, encoder even dimensions and limits. All local
checks pass with ASan/UBSan.

Apple verification for source `58dce8b654263fdb0100674c30ede7b01504a243`:

- [CI run 38492356472](https://github.com/DarkPaper2022/moonlight-ios/actions/runs/38492356472):
  iOS/tvOS Debug and Release simulator builds passed; input/layout tests passed
  with Apple clang.
- [IPA run 38492372219](https://github.com/DarkPaper2022/moonlight-ios/actions/runs/38492372219):
  unsigned iOS device Release build and IPA packaging passed.
- Package: `artifacts/Moonlight-PortraitKeyboard-v9.0.15.ipa` in the companion
  workspace, 3,123,802 bytes, SHA-256
  `8ab7e11713e47e92c6acee95300190643a6c6a22120545a1338e630b77568a28`.
  Verified archive integrity, internal version, adaptive native-resolution code
  in the binary, and removal of the old stretch method.
- Nginx file, software source, homepage, configuration and cache are synchronized
  to 9.0.15. Complete live HTTPS download matches size and SHA-256; the live source
  and homepage advertise 9.0.15 and the correct download/installation URLs.

Conclusion: the pixel-budget regression is explained by observed host/encoder
sizes and covered by a failing old-pipeline model plus the corrected negotiation
model. Builds and publication pass. iPad display and the new actual encoder size
still require an updated client and a fresh stream connection to confirm.

### R5 — landscape pixel reservation and four-button input (2026-10-14)

The user reported lower resolution after portrait-to-landscape rotation and
nonfunctional directional input, and approved four separate arrow buttons.
9.0.15 negotiated only the initial upper viewport. Rotation changed its render
size but retained that lower encoder resolution. 9.0.16 instead reserves a full
landscape native canvas before launch: a 834x1194-point window at 2x requests
2388x1668 pixels whether started portrait or landscape. The portrait upper area
still shows the desktop at full width and its original aspect ratio; local
90-degree fullscreen rotation has the same pixel budget as a landscape start.
No reconnect occurs on each rotation and the host display is not changed.

Read the primary [iSH ArrowBarButton implementation](https://github.com/ish-app/ish/blob/c5ebcabec14f1d8709e91e1905ce0edd7cb9c13c/app/ArrowBarButton.m).
Its Objective-C selectors are `beginTrackingWithTouch:withEvent:`,
`continueTrackingWithTouch:withEvent:` and `endTrackingWithTouch:withEvent:`.
Our old control accidentally used Swift-style `beginTracking:withEvent:` etc.,
so UIKit never invoked those methods. The portable transition test could not
catch this delivery bug. iSH uses timers to emit terminal actions, whereas
Moonlight must keep a GameStream keyboard DOWN active until UP (host repeat).

Replaced drag selection with four standard UIButton target/actions: TouchDown
presses immediately; lift inside/outside, cancel and drag exit release; drag
enter presses again. Each button has independent state for simultaneous holds.
Lifecycle cleanup releases every held direction once. The fixed 188-point arrow
row holds four 44-point buttons; other special keys scroll independently.

Verification: portable state/geometry tests pass under ASan/UBSan, including
identical native dimensions for portrait and landscape starts, correct portrait
desktop size, unchanged aspect ratio, diagonal holds and repeated cancellation.
Added a running UIKit simulator test that dispatches standard control events
through the real buttons, verifies immediate DOWN/UP delivery, cancellation,
re-entry, simultaneous keys, layout and removal cleanup. This checks event
wiring; physical finger delivery and LiveContainer behavior remain device checks.

Apple builds and publication: pending.

## Device acceptance checklist

Still pending; do not treat a CI build as device acceptance.

1. Connect from iPad; rotate to portrait using each button. Confirm video is in
   the upper half, the keyboard is below, and the stream stays connected.
2. With Native resolution, reconnect from portrait; verify the encoder uses the
   reserved landscape native pixels and the desktop keeps its proportions.
   Rotate to full-screen and compare sharpness with a landscape-start connection.
   Test fixed 1080p/custom settings and Native Safe Area, then type Latin and
   Chinese text, Backspace and Return; test the special-key row.
3. In an editor and a game, hold each direction for several seconds. Confirm
   repeat/movement continues after the finger stops moving and stops on release.
4. Press two arrows together, release one, drag outside/back inside; test
   Shift+arrows and Ctrl+arrows.
5. While holding a direction, open Control Center, hide the keyboard or exit
   the stream. Confirm there is no stuck key after returning or reconnecting.
6. Switch orientation repeatedly with both relative and absolute touch modes;
   verify touch alignment, fit, zoom reset and full-screen landscape restoration.
7. Test a host window that rejects scene rotation: switch locally in both directions,
   verify 90-degree full-screen video and correctly aligned absolute touches.
   Also test rotation lock, both landscape starting orientations, iOS 15 fallback,
   docked/floating/split keyboards and a hardware keyboard. Exit from portrait
   and confirm the host selection screen returns to landscape.
8. Check a small iPhone, and confirm tvOS still builds and keeps its existing UI.
