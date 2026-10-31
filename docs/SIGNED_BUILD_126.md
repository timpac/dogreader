# Build 126: audio controls and white theme

Base: signed build-125 branch at 701f349ad635d7d042208e83ce902477de225d85.
Audio handler and regression tests: PR #13 at 90d34cfd026c9ea20172724e0b775f49b4cafa79.

The white-theme main.dart/app_theme.dart and runtime Android files are preserved
from build 125. This build branch does not modify the theme-work branches or
merge either PR. The original production package is com.example.audiobook_app;
versionCode and visible build number are 126. No test-package suffix is used.
The existing DOGREADER_KEYSTORE_B64 secret is used only by signing steps.
The APK certificate SHA-256 must be
c5cc08d9757c0e92893a716204a26feb6157f5350a00dbb0b7962049d6d9d177.

The workflow runs full analysis and combined theme/reader/audio regression tests,
then signs and checks the APK before uploading it to a new private draft release.
It refuses a missing/wrong key and never overwrites existing release assets.
No cloud configuration, data migration, or paid narration is involved.

PR #13 native CI run 41138199459 passed all 12 candidate stages, including
notification and locked-screen touches and Stop/restart. The baseline passed
initial shade/lock controls but the Pause control was absent after Stop/restart;
this is not reproduction of the user's flashing but unresponsive button.
The phone is a Pixel 8 Pro, reportedly Android 17 Beta 3 (version unconfirmed).
The stock Android 13 emulator does not establish behavior on that beta/device.

Install as an update over build 125. Do not uninstall or clear storage: local
books, recordings and settings rely on the existing app data. Android's update
path retains that data with the verified package and signing certificate.
If rollback is needed, build the previous source using the same key and a
version code above 126; do not uninstall or force a downgrade.
