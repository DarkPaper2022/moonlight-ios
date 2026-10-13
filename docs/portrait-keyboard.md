# Portrait streaming and directional keyboard control

Version: 9.0.13. Base: `v9.0.11-audiodelay` (`0cd848e`).
The common-c gitlink remains `19d67932d77b5c86c7553b91b0294081573c60e2`;
this feature does not change the 9.0.11 audio implementation or host configuration.

## Usage

- During a connected iOS stream, tap the rotation button in the upper-right
  corner, or the rotation button on the keyboard bar, to switch orientation.
- Portrait reserves the upper half of the safe area for the video and the lower
  half for keyboard input. The system keyboard opens automatically. Video keeps
  its aspect ratio; absolute touch and mouse coordinates use the same viewport.
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

iOS 16+ uses Apple's
[window scene geometry request](https://developer.apple.com/documentation/uikit/uiwindowscene/requestgeometryupdate(_:errorhandler:))
and propagates the orientation policy through the reveal container. iOS 15 uses
`attemptRotationToDeviceOrientation` with the requested orientation mask; this
fallback still needs device validation. The keyboard avoidance constraint uses
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

Pending macOS CI: iOS/tvOS Debug and Release simulator builds, and unsigned
iOS Release IPA packaging. The development host is Linux without Xcode.

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
7. Test rotation lock, both landscape starting orientations, iOS 15 fallback,
   docked/floating/split keyboards and a hardware keyboard. Exit from portrait
   and confirm the host selection screen returns to landscape.
8. Check a small iPhone, and confirm tvOS still builds and keeps its existing UI.
