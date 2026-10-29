# Compact bilingual UI — 2026-10-30

Implemented:

- Home-screen display name: **Sensor Pro**, including the existing Chinese InfoPlist localization. Bundle identifier, storage location and StoreKit product identifiers are unchanged. This does not rename the App Store listing.
- Capture chrome now uses a fixed dark appearance with dark status badges and white settings/files actions; the settings controller explicitly stays light. Camera images are unchanged. HUD labels are bounded by each preview tile to prevent overlap.
- Settings retain expanded cards with smaller Dynamic Type baselines: 17pt section/header titles, 14–16pt labels/values and reduced spacing. The Settings title remains as a small navigation heading.
- The Developer card uses the actual TinyGrapeLab brand icon from `https://tinygrapelab.com/media/brand-icon.png`. The whole logo/name button opens `https://tinygrapelab.com/`.
- UI strings have English and simplified-Chinese resources, 105 matching keys. A Chinese preferred language (including zh-Hant) selects the Chinese UI; other languages use English. Purchase status, synchronization descriptions and common permission prompts are included. SDK diagnostic text that has no UI translation retains its original wording. Saved settings and recording metadata remain language independent.
- Existing Upgrade, Restore Purchase and Free/Premium behavior is retained. The blue/white app icon selected on October 29 is retained.

Validation:

- Device Debug build and test build: PASS. Bundled display name is Sensor Pro and both language resources are present.
- Localization key parity, duplicate keys and format argument parity: 105 keys PASS.
- iPhone 12 XCTest: 3/3 PASS: portrait settings/landscape return; purchase controls and developer action; preferred-language switching (en, zh-Hans, zh-Hant, fr→English).
- Native stable capture screenshot and Chinese settings/developer screenshots visually inspected. The XCTest capture screenshot immediately after relaunch can catch an orientation transition; use the native stable screenshot for capture-page review.
- Existing iPhone 12 recording-directory entries remain present after installation; these UI tests do not save new capture settings or delete recordings.
- iPhone 16's two XCTest attempts failed during runner bootstrap (exit 74/IDE connection), before tests ran. UI validation therefore uses iPhone 12, not a claimed iPhone 16 pass. No recording traversal was repeated for appearance changes.

Evidence: `.codex-baseline/bilingual-ui-validation/iphone12.xcresult`, `images/`, the before/after file lists and `/tmp/sensor-bilingual-*.log`. Large accessibility text sizes were not individually traversed.

## Subsequent settings layout refinement

Account is now the first expanded settings card, followed by a dedicated Mode card (with one full-width selector), then Camera/Capture/Focus/LiDAR/Sensors/Developer. Account actions are visible without scrolling. Capture returns to dark styling while settings remain light and compact.

iPhone 12: 3/3 targeted XCTest cases PASS (mode/camera draft preservation; portrait/landscape return; account controls plus explicit account→mode→camera ordering). Build and diff checks PASS. Original saved settings are restored after these tests. Evidence: `.codex-baseline/settings-order-validation/`.
