# ARKit to Standard mode transition fix — 2026-10-30

Source review found that Standard capability probes could open camera inputs while the saved ARKit session was still running. The ARSession failure callback also always queued an alert, including after the session was retired or the app had switched modes.

Opening settings now detaches and pauses the active ARSession before capability probing. A session-queue barrier drains already-delivered AR frame callbacks before queued probes touch camera formats. Canceling the settings draft resumes the same session after queued probes finish; saving a configuration resets the preview instead. Teardown invalidates the session identity and detaches its delegate before pausing and draining callbacks. Frame updates, preview rendering and error presentation reject retired-session work. Active ARKit failures remain reportable; error UI checks session identity and the current mode at presentation time rather than queuing another unguarded alert.

Validation: device Debug/test build PASS; iPhone 12 XCTest testSavedARKitToStandardTransitions PASS (136.396 s). It performs two actual saved Standard→ARKit→Standard cycles, cancels a Standard draft while in ARKit in each cycle, observes Standard for delayed errors, and makes two short Standard recordings. Both HEVC recordings decode successfully at 640×480, approximately 30 fps, with consistent timestamps/frame intervals. No capture.error appeared in this regression path. The test does not assert normal world-tracking quality in arbitrary lighting or scenes.

Existing recording directory entries were preserved. Original settings were backed up and restored. The fixed build is installed on iPhone 12 and iPhone 16; this regression XCTest ran on iPhone 12. Evidence: .codex-baseline/arkit-switch-validation/regression.xcresult and file-validation.json. No full capability traversal was repeated.

Apple references: [ARSession](https://developer.apple.com/documentation/arkit/arsession/) describes camera ownership and [pause()](https://developer.apple.com/documentation/arkit/arsession/pause()) describes suspending capture and tracking.
