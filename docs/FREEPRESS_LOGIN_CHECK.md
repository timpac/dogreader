# The Free Press login feasibility check

Build 158 is a prerequisite test, not completed signed-in importing.
Base: DogReader 2.0 build 157, 39f0f168306bdacc56644e2abb4cd2a9a538ce87.
Task branch: task/dogreader2-freepress-signin.

The publisher's sign-in entry points to Substack. The cloud browser denied the
sign-in navigation. That is not evidence that Android WebView succeeds or fails.
There is no attached phone or paid account available for testing. A cloud login
would also put the subscriber session outside the owner's device, contrary to
the requested privacy boundary. No credentials were requested or entered.

## Phone test

1. Install the APK as an update to Dog Reader 2.0. Do not uninstall or clear data.
2. Open Settings → The Free Press: test sign-in (also in Import a web article).
3. Tap the publisher's Sign in link. Enter your credentials only inside this
   embedded browser. Use email/password or email code if offered. External
   identity providers are intentionally outside this initial check.
4. If an email link opens Chrome, copy the link yourself into “Paste Free Press
   article or sign-in link” in DogReader and tap Open link in this app. Do not
   paste it into chat. The field is cleared after navigation and not saved.
5. Open a known paid article and confirm the whole text is available, including
   its ending. You may paste a normal thefp.com article URL into the same field.
6. Tap Done. Close/reopen DogReader and return to the check. Open the paid article
   again. Also try after force-stopping DogReader from Android Settings.
7. Report only: login works/fails, full paid text visible yes/no, retained after
   reopen/force-stop yes/no, and the non-secret wording of any visible error.
   Do not send passwords, codes, sign-in URLs, cookies or account screenshots.
8. Confirm your existing RSS subscriptions, book/article library, reading position
   and one previously downloaded recording remain available.

Session cookies and site storage remain in the app's private WebView profile.
They are not copied to Dart, the narration backend, GitHub, diagnostics or cloud
backup. Android 9+ uses a dedicated profile; earlier Android uses the app's
WebView profile. Both profile paths are excluded from Android backup and device
transfer. Screenshots, recent-task previews and autofill are disabled for this
screen; WebView debugging and console forwarding are disabled. HTTPS is required,
SSL failures are cancelled, mixed content and file/content access are disabled.
The app never opens arbitrary navigation destinations from this screen. The
publisher still receives its ordinary sign-in requests directly from the phone.

“Forget login” asks for confirmation, then clears only embedded-browser cookies,
site storage, cache and history. It leaves books, RSS, progress and audio alone.

## Next gate

Implement signed-in importing only after the phone test confirms login and paid
access. The intended importer will extract only article content already rendered
to the subscriber, locally, with no cookie export or server fetch. A login check
is not proof that the full article can be extracted safely. Preserve the RSS
entry identity, saved positions and audio when upgrading an RSS preview.

If the phone shows a persistent unsupported-browser error, challenge loop,
failed email-link return, or paid access unavailable despite successful login,
record that specific blocker before deciding whether PDF import is needed.
No PDF fallback has been implemented or selected.

## Verification scope

The Actions workflow runs Flutter analysis, focused widget/import/RSS regressions,
paid-operation and playback regressions before compiling the APK. Offline Android
instrumentation checks secure origin restrictions, private activity registration,
and backup exclusions. It does not use the publisher network or any subscriber
session. Signing, package/version, coexistence with original Dogreader, release
asset round-trip hashes and published source tag are checked separately.
Actual phone login, session persistence, subscriber article access and dual-app
behavior require the owner's test. No backend change or deployment is included.

## Owner's result and continuation (2026-11-17)

The owner confirmed sign-in, full paid-article access and persistence after
force-stop inside build 158 on the phone. Browser reading was slow. The next
implementation captures the article locally and returns to DogReader's normal
reader; see [Free Press importing](FREEPRESS_IMPORT.md). The build 158 APK and
its published artifacts are unchanged.
