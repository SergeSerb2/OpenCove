# Download page handoff

This change starts at `75fbec47915d0c32dc3d8f5985fdee5d762615db` and owns
only the landing-page presentation in `infra/updates/worker.mjs` and this file.
It does not publish a Worker, release, feed, or archive.

## Content and design

The page uses an original CSS illustration, system fonts, and no scripts,
images, remote assets, analytics, or forms. The illustration is explicitly
labelled and its decorative contents are hidden from assistive technology.
It is not an app screenshot or runtime evidence.

Feature copy follows the published-beta documentation at `f252d78`, especially
its `README.md` feature list and `docs/updates.md` verification record. It covers
Now Playing, Calendar, the file tray, persistent timers, available system status,
and display/appearance choices. Calendar and other protected features are
described as optional and permission-dependent. There is no automatic-Duo or
middle-click marketing, parity claim, performance claim, or universal player,
hardware, or OS compatibility claim.

The download URL, version, byte count, and checksum still come only from
`publishedRelease`. Its validation and R2 size/existence check are unchanged.
The page displays signed/notarized download copy only when that function returns
a release. These statements depend on the publisher's descriptor and release
verification; the Worker does not inspect signatures or hash archive bytes.
Absent or invalid descriptors expose no archive link, checksum, metadata link,
or signing claim. Feed presence remains a separate nonempty-object check and
does not establish that the feed or its enclosures are valid.

ZIP and DMG installation instructions follow the validated archive extension.
The page links to source, compatibility, privacy, and release information. No
native implementation details or internal acceptance gates appear in its flow.

## Security boundary

The only header change is on the successful `/` HTML response, including HEAD:
the existing CSP gains a `style-src` with one SHA-256 hash. It permits exactly
the static `LANDING_STYLE` text. `default-src 'none'`, base/frame/form restrictions,
and every other security/cache header remain in place. There is no script or
external-resource exception, `unsafe-inline`, nonce, style attribute, or CSS URL.
Every other route retains its existing response policy.

Keep `LANDING_STYLE_SHA256` synchronized with the UTF-8 text **between** the
stylesheet template literal's backticks, including its leading/trailing newline.
The template contains no JavaScript interpolation or escapes. A CSS edit without
the matching digest fails closed: browsers block the stylesheet. The semantic
HTML still supplies the content and links.

`docs/update-hosting.md` describes the prior unstyled HTML. This focused handoff
supersedes its statement that the HTML contains no styles. The HTTP, publication,
and release contracts in that document remain unchanged.

## Validation in this worktree

- `node --check infra/updates/worker.mjs`: passed.
- `git diff --check`: passed.
- Static comparison with the base revision: descriptor validation, common
  response/security helpers, routing decisions, health/feed behavior, object
  streaming, conditions, range handling, and failure responses are unchanged.
  The sole fetch-handler diff adds the hash-bound CSP on `/`.
- The declared stylesheet digest matches its literal UTF-8 bytes.

No server, browser, Worker runtime, R2/API call, build, native app, permission
operation, signing command, profiling, or deployment ran here. There is no
TypeScript package in this change. Static checks do not prove rendered layout,
accessibility, CSP enforcement, or HTTP behavior.

## Parent validation before deployment

1. Run the real Worker/R2 HTTP checks from `docs/update-hosting.md`. Cover GET
   and HEAD on `/`, `/health`, `/download`, `/release.json`, the feed/signature,
   and versioned assets. Retain method/path rejection, stream/metadata races,
   conditionals, range/If-Range/416, and cache/security-header checks. Only the
   landing HTML's CSP should differ from the previous header contract.
2. Exercise real storage states: valid ZIP and DMG descriptors, absent/invalid/
   oversized descriptors, missing or size-mismatched archives, absent/empty feed,
   valid descriptor without a feed, feed without a valid descriptor, and storage
   errors. The unavailable page must have no download or metadata action. Errors
   must keep their generic fail-closed responses and Retry-After behavior.
3. Open the real Worker in the browser at 320, 375, 768, and 1440 CSS pixels.
   Check no horizontal overflow, readable line lengths, header wrapping, 200%
   text scaling and 400% zoom/reflow, the checksum's wrapping, and large download
   targets. Review the illustrative panel and both unavailable/feed messages.
4. Verify that the response's CSP permits the exact stylesheet and blocks any
   extra inline styles/scripts and external resources. Inspect the real network
   log: this HTML should make no asset, font, analytics, or script requests.
   Check the page with styles disabled as well.
5. Use keyboard navigation to check the skip link, navigation, download link,
   install links, checksum disclosure, and footer. Check visible focus, contrast,
   forced colors, reduced motion, heading/landmark order, and screen reader link
   names. The illustration must not expose fake controls as interactive elements.
6. Download the actual published archive through the displayed link and compare
   its URL, size, and SHA-256 with the publisher's verified metadata. Confirm ZIP
   or DMG install copy and native update guidance against the published beta.
   Deployment and all native/install/update checks remain with the parent.

## Public primary references

- [W3C CSP: matching style elements to hashes](https://www.w3.org/TR/CSP3/#match-element-to-source-list)
  defines the exact-source hash exception used for this stylesheet.
- [W3C WCAG reflow guidance](https://www.w3.org/WAI/WCAG22/Understanding/reflow.html)
  explains the 320 CSS pixel / 400% zoom review target. This is a validation
  target, not a claim of measured conformance.
- [Apple: install apps from the internet](https://support.apple.com/guide/mac-help/install-and-uninstall-other-apps-mh35835/mac)
  informs the disk-image guidance. The ZIP unpacking and app/update instructions
  also follow OpenCove's published-beta documentation.
