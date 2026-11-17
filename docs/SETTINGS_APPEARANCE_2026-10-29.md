# Settings appearance and developer information — 2026-10-29

The portrait settings page now uses a light grouped background, white cards, blue actions and semantic label colors. Camera preview stays dark. Settings titles and primary values are larger; labels support Dynamic Type and the main settings fonts use UIFontMetrics. Sensor switches occupy full-width rows. Resolution and frame rate occupy separate rows so their values remain readable. Cards remain expanded.

A separate Developer card names TinyGrapeLab and provides a More Information action opening https://tinygrapelab.com/ in the system browser. Upgrade, Restore Purchase and the Free/Premium status remain in the Account card, with their existing purchase handlers. Capture capability discovery, saving, recording and synchronization behavior are unchanged.

Validation: the device Debug build succeeds. On the connected iPhone 16, testPortraitSettingsAndLandscapeReturn and testPurchaseControlsRemainAccessible both pass; the latter also verifies the TinyGrapeLab label and the developer action. Screenshot export passes. The website responds HTTP 200. The device's preexisting top-level recording entries remain present after installation. The last layout polish removes card outlines and stacks Resolution/Frame rate vertically after reviewing actual device screenshots.

The user selected the second blue-background/white-symbol icon concept. All 13 existing AppIcon raster sizes are regenerated from that selected design, including the 1024px App Store image. Large accessibility text sizes have not been individually traversed on the device.

Evidence: `.codex-baseline/light-settings-validation/` and `/tmp/sensor-light-*.log`. Local screenshot evidence is excluded from Git.
