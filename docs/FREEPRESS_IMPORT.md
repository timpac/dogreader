# Full Free Press articles in DogReader 2.0

This continues the isolated task based on build 157,
39f0f168306bdacc56644e2abb4cd2a9a538ce87, on
`task/dogreader2-freepress-signin`. No merge or backend deployment.

The owner confirmed on the phone that build 158 signs in, opens a complete paid
article and retains paid access after force-stopping and reopening DogReader.
Chrome session transfer was never assumed. The browser's speed was poor for
reading; it now serves only authentication and loading/capturing the article.
Build 159 adds the import and ordinary reader handoff. Actual subscriber capture
on the phone remains an acceptance check, not a result claimed from CI.

## Read a subscriber article

1. Install the new APK over DogReader 2.0 without uninstalling or clearing storage.
   The private WebView profile name is unchanged, retaining the build 158 login.
2. Keep using RSS to discover posts. Open a Free Press post and tap **Read full
   article with my subscription**. Alternatively paste the normal article URL
   into **Import a web article**. Settings also has **The Free Press: sign in and
   import** for managing login or choosing an article manually.
3. The selected article opens directly with your device session. Sign in there
   if the publisher has expired your session. Chrome login remains separate.
4. Tap **Save and read in DogReader**, check the displayed ending, then confirm
   **Save and read**. A preview, paywall or login shell is rejected. Wait/reload
   if the publisher page has not rendered its article yet. The capture limit is
   180,000 text characters; larger articles fail without saving a partial copy.
5. DogReader opens the saved text in its existing reader. The browser is closed
   and destroyed. Headings, paragraphs, quotes, lists and scene breaks are kept.
   Later opens from RSS or the book library read the local copy without a browser
   or network. RSS shows **Full text saved offline** when such a copy exists.
6. Use the existing narration controls if wanted. Importing itself never sends
   paid AI or backend requests. Existing one-request narration consent applies.

## Privacy boundary

Cookies, credentials, email codes, sign-in link queries and website storage stay
inside the same Android private WebView profile as build 158. Backup/device
transfer exclusions, disabled debugging/console forwarding/autofill, secure window,
HTTPS restrictions and SSL error cancellation are retained. Forget login clears
only browser cookies/site storage/cache/history after confirmation; it leaves
saved articles, RSS, reading progress and audio intact.

There is no JavaScript interface exposed to pages. On an explicit capture, a
bundled script reads only visible article elements and the visible title. It
never serializes the page DOM, scripts/JSON state, inputs/forms, cookies, request
headers or localStorage. Hidden text and visible paywalls are excluded/rejected.
The activity returns only bounded article blocks, a title and a public Free Press
article path with all queries/fragments removed. Dart validates that narrow
schema before storing the copy locally. Neither session data nor article text is
logged by the importer. Article text reaches narration services only through the
existing, separately approved narration action. No backend import endpoint exists.

## Existing data and compatibility

Existing files and book/article IDs are not rewritten. New full copies use the
existing version-1 article JSON with an optional `localRevision: true` field.
Missing/false retains the exact old ID calculation. True derives an equally short,
content-specific ID from the canonical URL and text hash. Repeated identical
captures deduplicate, and capture saves serialize with ordinary article imports.
This keeps the immutable ArticleStore rule: a different text never overwrites an
existing article, its reading positions or narration/audio ID. A full copy is
labelled **Full article** and has its own progress. Existing previews and their
progress/audio remain available. No RSS state or EPUB format migration occurs.

## Acceptance and automated checks

- On the phone, import a known paid article; check opening and ending, reader
  navigation and airplane-mode reopening. Confirm a subsequent RSS tap opens the
  local reader and does not reopen the publisher website.
- Confirm existing subscriptions, EPUB/article libraries, old reading position
  and a previously downloaded recording remain available after the update.
- Test narration only with the usual explicit one-request approval, if desired.
- CI uses synthetic, offline WebView fixtures, not a subscriber account. Checks
  cover visible extraction/structure, exclusion of hidden state/forms/navigation,
  paywall rejection, empty/oversized pages, URL sanitization, local round-trip and
  duplicate saves, immutable legacy data/audio/progress, widget reader handoff and
  offline reuse, RSS/import/playback policy regressions and APK identity/signing.
- No PDF fallback was selected: actual phone results established the signed-in
  article route is viable. Publisher markup changes can still need selector fixes.
