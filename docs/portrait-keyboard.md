# Portrait streaming and directional keyboard control

Version: 9.0.14. Base: `v9.0.11-audiodelay` (`0cd848e`).
The common-c gitlink remains `19d67932d77b5c86c7553b91b0294081573c60e2`;
this feature does not change the 9.0.11 audio implementation or host configuration.

## Usage

- During a connected iOS stream, tap the rotation button in the upper-right
  corner, or the rotation button on the keyboard bar, to switch orientation.
- Portrait reserves the upper half of the safe area for the video and the lower
  half for keyboard input. The system keyboard opens automatically. Video fills
  the entire upper viewport, retaining the whole desktop and stretching if the
  aspect ratios differ. Absolute touch and mouse coordinates use the same geometry.
- The keyboard button shows or hides the keyboard in either orientation. The
  existing three-finger gesture and Done button still work. Switching back to
  landscape hides the keyboard and restores the full-screen stream.
- Press the `↕ ↔` control, drag up/down/left/right, and keep the finger down to
  hold that keyboard arrow. Changing direction releases the old key before
  pressing the new one. Returning within 10 points of the initial touch location
  releases the key. Lifting or cancelling releases it too.
- Direction input sends keyboard DOWN/UP events, including modifier flags for
  latched Shift/Ctrl/Alt/Windows keys. Sunshine handles keyboard autorepeat;
  the client does not synthesize repeated taps or gamepad directions.
- The direction control and rotation button remain visible on narrow screens;
  the special-key row scrolls horizontally independently of the direction control.
- Rotation, keyboard dismissal, application inactivity and stream exit release
  held toolbar keys. Viewport changes reset absolute-mode zoom to fit.

## Layout and platform details

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
LiveContainer. Apple builds and device acceptance remain pending for 9.0.14.

## Device acceptance checklist

Still pending; do not treat a CI build as device acceptance.

1. Connect from iPad; rotate to portrait using each button. Confirm video is in
   the upper half, the keyboard is below, and the stream stays connected.
2. Type Latin and Chinese text, Backspace and Return; test the special-key row.
3. In an editor and a game, hold each direction for several seconds. Confirm
   repeat/movement continues after the finger stops moving and stops on release.
4. Change direction and return to neutral; test Shift+arrows and Ctrl+arrows.
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
