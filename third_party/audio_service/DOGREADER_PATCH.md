# Narrow audio_service 0.18.19 native repair

Source: pub.dev `audio_service-0.18.19.tar.gz`, SHA-256
`95f3267f3449eb5cf71c8fcf1d556f57af1e898e2dc5815fb168d1843653edb7`,
identical to Dogreader's previous lockfile. Library code, Android resources,
Darwin implementation, manifest and build configuration are retained from that
archive. Example/test projects are omitted. LICENSE is retained.

Runtime differences are restricted to:

- `AudioService.java`: service destruction no longer clears the listener owned
  by a surviving Flutter engine. Native command entry is recorded before the
  listener-null guard, with service/session identity and listener presence.
- `AudioServicePlugin.java`: detaching the engine that owns the handler clears
  that listener. Record engine retention and bridge dispatch separately.
- `MediaTransportDiagnostics.java`: bounded asynchronous native journal, with
  no media content/arguments, credentials or paths. Two 64 KiB files, 64 queued
  writes; snapshot is included by the app's existing diagnostic export worker.

No additional session, notification manager, player or retry loop is introduced.
Dart library source and APIs are unchanged. The app uses a local package path
so the correction is reproducible without editing a shared pub cache or fetching
an unpinned fork. Reevaluate this patch against a maintained upstream release
that corrects the lifetime mismatch; do not upgrade unrelated dependencies.

`tools/prepare_audio_service_baseline.py` temporarily restores the two upstream
ownership statements for the isolated Android regression probe. CI restores the
repaired files before its candidate build; the release uses a fresh checkout.
