# Article import: public RSS/Atom fallback

This feature branch is based on Dog Reader 2.0's experimental integration branch
at `7ce8b93a1b06a4535c2336fb1d10953c61fffbb4`. It changes manual article import,
not subscriptions, polling, narration generation, backend services or releases.

## Extraction and matching

1. Fetch and extract HTML first. HTTP 200 is insufficient: require readable
   article text, a title, and no explicit preview/truncation signal. Where the
   publisher provides an article word count, reject clearly shorter bodies.
2. For missing/insufficient public HTML, inspect alternate RSS/Atom links and
   bounded origin conventions (`/feed`, `/rss.xml`, `/atom.xml`, `/feed/atom`).
   At most four distinct feed candidates are requested for this one import.
3. Parse RSS 2.0 or Atom with the existing locked XML parser. Match exact article
   URL identities (requested, redirected and trusted canonical/og URLs), allowing
   ordinary HTTP/HTTPS, www and trailing-slash aliases and known tracking-query
   removal. Opaque entry IDs require an exact explicit page identifier and the
   same publication. Titles and approximate slugs are never used for matching.
4. Prefer RSS `content:encoded` and Atom inline `content` (HTML, XHTML or text).
   Summary/description-only content needs positive page article-word-count
   evidence covering the complete field, plus the same body validation. A long
   description alone is insufficient. Referenced Atom `content src` is rejected.
5. Clean the selected body through the same HTML/text conversion as normal
   extraction. Store only the requested matching article, not the other posts
   downloaded inside its feed. Explain absent entries, including Substack's
   recent-post window, and distinguish preview-only entries.

Full-content fields are publisher assertions, not an acoustic or mathematical
completeness guarantee. Explicit preview controls/attributes and contradictory
word-count evidence reject them. Missing public article content remains an
error; no short excerpt or similarly titled post is substituted.

## Cleanup and reader compatibility

New imports preserve wording, title, author, publication, normalized original
URL and canonical identity. Blocks retain headings, paragraphs, explicit line
breaks, preformatted line breaks, quote/list/caption roles, footnote text, and
meaningful section breaks. Inline emphasis and bold use the existing reader's
`StyledRange`, with half-open UTF-16 coordinates. Script/interactive/hidden
elements, newsletter/social/navigation/advertising widgets and related-post
clutter are removed before constructing text. Entities are decoded by the HTML
parser; whitespace is normalized once, without joining separate paragraphs.

Before:

```html
<div class="subscribe-widget"><p>Subscribe now</p></div>
<p>Read the <a href="https://example.org/source?utm_source=feed&amp;id=7">source notes</a>.<br>Keep this intentional line break.</p>
```

Saved reader/narration text:

```text
Read the source notes.
Keep this intentional line break.
```

The link target is retained separately as `https://example.org/source?id=7`.
Link labels stay in the prose; destinations/tracking parameters are not appended
to narration. Web link targets can be selected/copied from **Article links** in
article details. The current reader has no inline link activation or image
renderer. Captions are retained as text; images are not loaded. Quotes use the
existing italic range presentation, while list items remain separate blocks in
reading order. This adds no rendering engine or external URL launcher.

`ArticleBlock` has optional spans/roles; `ImportedArticle` has optional
publication/original-URL fields. Legacy JSON defaults remain supported. Text is
still the exact saved blocks joined by two newlines. No stored article is
re-extracted or migrated. Content hashes, IDs, reading state, audio paths and
frozen dictionary/recording maps retain their established contracts. Existing
cached imports remain immutable, including any previously saved poor extraction.
URL aliases are deduplicated before/after fetching without rewriting an existing
saved version. The EPUB parser, audio handler and experimental cloud-consent
policy are unchanged.

## Network boundaries

Public unauthenticated HTTP(S) only, with no cookies, tokens or browser session
transfer. Validate every redirect and DNS result; pin new sockets to validated
public addresses instead of performing a second unchecked DNS lookup. Reject
loopback/private/link-local/metadata destinations, mixed public/private DNS
answers, unsafe schemes/user info/ports, and unvalidated proxy connections.
HTTPS certificate verification remains active.

Keep the existing eight-second connection and 30-second overall import limits.
Bound HTML responses to 2 MiB, feeds to 4 MiB, aggregate received content to
8 MiB and redirects to five per candidate (64 KiB maximum redirect body).
Reject XML document/entity declarations. Explicit HTTP 401/402/403/429,
paywall/subscription restrictions and known article-length limits stop rather
than seeking alternative access. No authentication/paywall workaround is added.

## Fixtures and limits

Saved synthetic fixtures use Astral Codex Ten/Substack-shaped URLs, metadata and
RSS structure; they contain original test prose, not copied publication articles.
Tests perform no live website requests. Live ACT behavior, other publisher
layouts and real-device reader appearance remain acceptance work. Description
feeds without positive completeness evidence are intentionally rejected; older
posts absent from all available feeds cannot be recovered by this feature.

Focused verification covers HTML preference, Substack fallback, RSS/Atom full
fields, missing/truncated entries, explicit IDs, metadata length checks, cleanup,
Unicode/UTF-16 spans, stable offline text/progress, deduplication, unsafe URLs/DNS/
redirects, access restrictions and XML declarations. Existing article, summary,
navigation and fake-player dictionary/seek regressions are reused/run in affected
batches. No full suite, emulator, APK build, paid narration, summary request,
backend mutation, merge or release is part of this work.

Verification result: **36 distinct focused Flutter cases passed across affected
batches** (13 new RSS/cleanup/network cases plus 23 existing article/navigation/
summary/dictionary-queue cases). The final changed-extraction batch passed all
23 cases. Repository static analysis and whitespace checks are clean. The XML
package was already locked at 6.6.1; only its direct-dependency classification
changes, with no package version upgrade.

## Feed-fetch failure follow-up

For the reported `/p/escaping-the-outside-criticism-trap` URL, a single public
check returned HTTP 200 HTML with no readable body and HTTP 200 RSS containing
the exact entry. The released parser extracted 10,718 UTF-16 units offline.
The phone's original failing feed response was not captured, so its exact
transport/response cause remains unconfirmed.

Feed requests now ask caches to revalidate (`Cache-Control: no-cache`) without
extra requests. HTTP/XML failures retain their primary feed URL and safe cause
instead of being relabeled as article absence. The recent-post-window explanation
requires at least one successfully parsed feed. XML error excerpts and query
strings are excluded from diagnostics. Access restrictions, private-address
checks, matching, size/time limits and saved-text contracts are unchanged.

Seventeen focused tests and static analysis pass. Revalidation is a freshness
mitigation, not proof that caching caused the phone failure. Device acceptance
needs a separately approved APK; this source patch does not update build 139.

## HTTPS transport correction

The build-140 phone result exposed HTTP 400 from the feed endpoint. The custom
DNS-pinned connection factory returned a plain Socket even for HTTPS. Dart uses
that custom socket directly; it does not add TLS automatically. Plain HTTP sent
to port 443 explains the rejected requests.

HTTPS now uses SecureSocket.startConnect with the validated DNS lookup address,
retaining its original hostname for SNI/certificate verification and its pinned
IP without a second lookup. HTTP stays unchanged. A hostname consistency guard
prevents validating a different hostname. Production trust remains the system
trust store; no certificate exceptions are allowed.

A real loopback TLS regression failed with the old code and passes after the
fix. Trusted correct-host TLS succeeds; wrong-host and untrusted certificates
fail; plain HTTP still works. Nineteen focused HTTPS/feed tests and static
analysis pass. These tests replace mocked transport assumptions with an actual
TLS exchange; live phone acceptance is still required.
