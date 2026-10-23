# OpenCove update host

This is a separate public download and Sparkle feed host. Its only resources are
the `opencove-updates` Worker, the private `opencove-releases` R2 bucket, and the
Worker Custom Domain `opencove.sergeserbinenko.com`. Do not reuse or change T3's
Workers, release buckets, DNS records, or relay. This source does not create any
resource or publish a release by itself.

The Sparkle feed URL is:

```text
https://opencove.sergeserbinenko.com/appcast.xml
```

The Worker has no dependencies. It is plain ESM JavaScript. Use **Wrangler
4.152.0**, the current stable npm release checked on 2026-10-23, with Node.js
22 or later. Use an exact temporary package runner; this Swift repository does
not need a new npm dependency tree or lockfile just to run a deployment CLI.
The compatibility date is `2026-10-19`, supported by this pinned runtime.

## Public interface

Only `GET` and `HEAD` are accepted. Every other method returns `405` with
`Allow: GET, HEAD`, including requests to nonexistent paths. There is no public
upload, admin, listing, proxy, or account endpoint.

- `/` is an original, script-free HTML page. It links to the source repository
  and release information. Before publication it says that no feed is present.
  After publication it links to the feed. It never invents an installer link,
  release version, signing status, download count, or compatibility claim.
- A publisher-controlled `release.json` enables a direct download on `/` and
  `/download`. The descriptor must have a bounded version and same-origin
  `/releases/<version>/<archive.zip-or-dmg>` path, a lowercase SHA-256, a positive
  integer byte count, `architecture: "universal2"`,
  `minimumSystemVersion: "15.0"`, and `notarized: true`. The referenced R2 object
  must exist with the same byte count. Invalid or missing descriptors yield no
  download link; `/download` and `/release.json` return `503`. The descriptor is
  at most4096bytes. Returned text is escaped. The publisher must verify the
  actual signature, notarization and remote archive hash before publishing this
  descriptor; the Worker does not re-sign or hash the archive on each request.
  `/download` redirects only to that validated relative path. `/release.json`
  returns only validated public fields.
- `/health` checks whether a nonempty `appcast.xml` object is readable. It returns
  `200` with `{"status":"feed-present","feedPresent":true}` or `503` with
  `{"status":"awaiting-release","feedPresent":false}` and `Retry-After: 60`.
  This is a limited publication check. It does not parse the feed, check every
  enclosure, validate signatures, or prove app/device readiness. Storage errors
  return a generic `503`; they disclose no account or device details.
- `/appcast.xml` reads the exact `appcast.xml` R2 key. An absent or empty feed
  returns `503` and `Retry-After: 60`. It never returns an empty success feed that
  could mean “up to date.”
- `/appcast.xml.sig` reads that exact optional key. It returns `404` if absent.
  Only publish it if the app's agreed feed-signature scheme actually uses it.
- `/releases/<version>/<asset>` maps to the identical R2 key without the leading
  slash. Version is 1–64 ASCII characters; asset is 1–128. Both must start with
  an ASCII letter or digit and contain only letters, digits, `.`, `_`, or `-`.
  Consecutive dots, encoded path characters, extra path components, and dot
  segments are rejected. Missing files return `404`. No bucket listing is used.

Feeds, HTML, health responses, signatures at the feed path, and errors use
`Cache-Control: no-store, max-age=0`. Existing versioned assets use
`public, max-age=31536000, immutable, no-transform`. Never replace bytes at a
versioned key. Use a new version or asset name for any correction. Keep old
enclosures available while any retained feed or installed client can use them.

Objects stream from R2. The Worker controls content type, download filename,
cache policy, length, ETag, and last-modified headers instead of trusting stored
HTTP metadata. ZIP and DMG types are explicit; checksums and text use plain text;
other assets use `application/octet-stream`. Release assets are attachments.
GET/HEAD support `If-Match`, `If-None-Match` (including weak comparisons),
`If-Modified-Since`, and `If-Unmodified-Since` with HTTP precedence. GET supports
one byte range, suffix/open-ended ranges, and `If-Range`; unsatisfied ranges
return `416` with `Content-Range: bytes */<size>`. Malformed and multiple ranges
are ignored with a full response. HEAD ignores Range and reports the full length.
A GET uses an R2 ETag precondition to keep the streamed bytes and metadata in
agreement if the feed changes during the request; retry a generic `503` if it races.

All Worker responses set a strict CSP, `nosniff`, frame denial, no-referrer,
restricted browser permissions, and HSTS for this host. The HTML has no scripts,
styles, forms, or remote assets. Request values and R2 metadata are never interpolated into HTML. The download
link uses only escaped, validated fields from the bounded release descriptor. No credentials or signing keys belong in the
Worker, bucket, feed, source tree, command arguments, or logs.

## Pinned command and private authentication

Run all commands below from `infra/updates`. For a portable exact pin:

```sh
cd infra/updates
opencove_wrangler() { npx --yes wrangler@4.152.0 "$@"; }
opencove_wrangler --version
```

The deployment owner can instead define the same shell function with
`node "$OPENCOVE_WRANGLER_JS" "$@"` when `OPENCOVE_WRANGLER_JS` points to an
already cached `wrangler/bin/wrangler.js`. First read its enclosing package's
`package.json` and confirm version `4.152.0`. This avoids a package download.
Do not commit a machine-specific cache path. The exact top-level CLI pin does
not lock its transitive npm dependencies; keep the inspected cache for a fully
repeatable deployment, or add a reviewed lockfile if a package workflow is added.

Use the existing private process environment for `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID`. Wrangler officially reads both names. `account_id` is
deliberately absent from `wrangler.jsonc`; do not insert an account ID or token.
Do not echo the environment, put credentials in command arguments, use debug
logs, add Worker secrets, request another token, or run an interactive login.
Do not pass either variable as a Worker `--var`.

For local checks, remove both variables from the local child process with
`env -u CLOUDFLARE_API_TOKEN -u CLOUDFLARE_ACCOUNT_ID`. Also set
`WRANGLER_SEND_METRICS=false`. Keep local R2 under a new temporary directory.
Never add `--remote` or `remote: true` during local checks. Do not place private
credentials in `.dev.vars`; this Worker needs none.

## Bounded local HTTP check plan (deployment owner)

These are real Wrangler/workerd/R2 HTTP checks, not mocked unit tests. The source
implementation agent does not run servers or these CLI commands. Run this plan
before any cloud creation or deploy. Use a fresh temporary directory and port
`8797`; stop if that port is already occupied. The snippets use the cached
launcher from the previous section so local checks need no package install.

In the first shell, from `infra/updates`, select a fresh directory and start the
server in the foreground. Set the same `OPENCOVE_HTTP_WORK` path in the second
shell. Keep the directory until all checks finish; it contains only local fixtures.

```sh
OPENCOVE_HTTP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/opencove-http.XXXXXX")"
env -u CLOUDFLARE_API_TOKEN -u CLOUDFLARE_ACCOUNT_ID WRANGLER_SEND_METRICS=false \
  node "$OPENCOVE_WRANGLER_JS" dev --local --ip 127.0.0.1 --port 8797 \
  --persist-to "$OPENCOVE_HTTP_WORK/r2" --config wrangler.jsonc
```

In the second shell define bounded HTTP and local-R2 commands:

```sh
opencove_http() { curl --silent --show-error --connect-timeout 3 --max-time 10 "$@"; }
opencove_local_r2() {
  env -u CLOUDFLARE_API_TOKEN -u CLOUDFLARE_ACCOUNT_ID WRANGLER_SEND_METRICS=false \
    node "$OPENCOVE_WRANGLER_JS" r2 object "$@" --local \
    --persist-to "$OPENCOVE_HTTP_WORK/r2" --config wrangler.jsonc
}
opencove_http -i http://127.0.0.1:8797/
opencove_http -i http://127.0.0.1:8797/health
opencove_http -i http://127.0.0.1:8797/appcast.xml
opencove_http -I http://127.0.0.1:8797/appcast.xml
opencove_http -i http://127.0.0.1:8797/appcast.xml.sig
opencove_http -i http://127.0.0.1:8797/releases/http-check/fixture.zip
opencove_http -i -X PUT --data 'denied' http://127.0.0.1:8797/appcast.xml
```

Expect root `200` with the no-feed text, health and GET/HEAD feed `503` with
Retry-After, missing signature/archive `404`, and PUT `405`. Check CSP and
`no-store` on all these responses. Also send POST, PATCH, DELETE, and OPTIONS
to `/` and expect `405`. None may create a readable object.

Seed a clearly local, unsigned fixture. Its `.zip` name tests HTTP metadata;
its 16 bytes are deliberately not a distributable archive. Never upload this
fixture or feed to the cloud.

```sh
python3 - "$OPENCOVE_HTTP_WORK" <<'PY'
from pathlib import Path
import sys
work = Path(sys.argv[1])
(work / "fixture.zip").write_bytes(b"0123456789abcdef")
(work / "appcast.xml").write_text(
    '<?xml version="1.0"?><rss version="2.0"><channel>'
    '<title>Local HTTP fixture only</title></channel></rss>\n')
PY
opencove_local_r2 put opencove-releases/releases/http-check/fixture.zip \
  --file "$OPENCOVE_HTTP_WORK/fixture.zip" --content-type application/zip
opencove_local_r2 put opencove-releases/appcast.xml \
  --file "$OPENCOVE_HTTP_WORK/appcast.xml" --content-type application/xml
opencove_http -D "$OPENCOVE_HTTP_WORK/asset.headers" \
  -o "$OPENCOVE_HTTP_WORK/download.zip" \
  http://127.0.0.1:8797/releases/http-check/fixture.zip
cmp "$OPENCOVE_HTTP_WORK/fixture.zip" "$OPENCOVE_HTTP_WORK/download.zip"
opencove_http -I http://127.0.0.1:8797/releases/http-check/fixture.zip
opencove_http -i -H 'Range: bytes=2-5' http://127.0.0.1:8797/releases/http-check/fixture.zip
opencove_http -i -H 'Range: bytes=-4' http://127.0.0.1:8797/releases/http-check/fixture.zip
opencove_http -i -H 'Range: bytes=12-' http://127.0.0.1:8797/releases/http-check/fixture.zip
opencove_http -i -H 'Range: bytes=16-' http://127.0.0.1:8797/releases/http-check/fixture.zip
opencove_http -i -H 'Range: bytes=0-1,4-5' http://127.0.0.1:8797/releases/http-check/fixture.zip
opencove_http -i -H 'If-Match: "absent"' http://127.0.0.1:8797/releases/http-check/fixture.zip
opencove_http -i -H 'If-Range: "absent"' -H 'Range: bytes=2-5' \
  http://127.0.0.1:8797/releases/http-check/fixture.zip
opencove_http --path-as-is -i http://127.0.0.1:8797/releases/http-check/%2e%2e/appcast.xml
opencove_http --path-as-is -i http://127.0.0.1:8797/releases/http-check/../../appcast.xml
opencove_http -i http://127.0.0.1:8797/releases/
opencove_http -i http://127.0.0.1:8797/appcast.xml
opencove_http -i http://127.0.0.1:8797/health
```

Expect full GET/HEAD length `16`, ZIP type, attachment filename, quoted ETag,
and immutable caching. Ranges return `206`, correct length/Content-Range, and
`2345`, `cdef`, `cdef` respectively. The unsatisfied range returns `416` with
`bytes */16`; multiple ranges and failed If-Range return the full `200`.
Failed If-Match returns `412`. Traversal and listing paths return `404`.
If the server normalizes a traversal path before the Worker sees it, verify it
can only reach the same fixed public routes; it must never read any other R2 key.
The feed remains `no-store`; health becomes `200` with `feed-present`.

Copy the observed ETag from `asset.headers` into GET and HEAD `If-None-Match`
requests: both must return `304` with no body. Repeat with `W/` before the tag.
The matching ETag in If-Match must return `200`; a matching If-Range plus Range
must return `206`. Last-Modified in If-Range must give `206`; a different date
(including a future date) must give the full `200`. Copy Last-Modified into
If-Modified-Since and expect `304`;
If-Unmodified-Since from 1990 must return `412`. A nonmatching If-None-Match
must take precedence over a future If-Modified-Since and return `200`.
Check HEAD with Range returns `200`, full length, and no body. Upload a zero-byte
local feed and confirm GET/HEAD feed and health return `503`. Delete the local
feed and confirm the initial empty state returns. Stop the foreground server.
Do not deploy if these checks fail.

## Create and deploy (deployment owner only)

Recheck that the exact Worker, bucket, and hostname are still unused. Stop on a
collision; do not adopt or overwrite another resource. Confirm the parent-owned
account environment refers to the active `sergeserbinenko.com` zone. Review the
config before these mutations. The host uses a **Worker Custom Domain**, not an
R2 public domain or a wildcard Worker route.

```sh
opencove_wrangler r2 bucket create opencove-releases
opencove_wrangler deploy --config wrangler.jsonc
```

Wrangler provisions the configured Custom Domain and certificate during deploy.
Do not manually create a DNS target or change unrelated records. Leave the R2
bucket private: no `r2.dev` URL, public bucket domain, or CORS setup is needed.
No account identifier, auth token, or Sparkle private key is a Worker binding.

Before publication, repeat the empty-state HTTP checks against
`https://opencove.sergeserbinenko.com`, with certificate verification enabled
(never `curl -k`). Confirm TLS, the exact hostname, `503` for the absent feed,
`404` for missing archives, and `405` for public writes. Check no challenge or
login page blocks native Sparkle clients. Keep bounded timeouts. A Worker deploy
does not establish that a trusted application release exists.

## Publish a real release (deployment owner only)

The app/release workflow owns packaging, Developer ID signing, notarization,
Sparkle public-key configuration, and the official Sparkle signing tool. Never
generate a new signing key just to deploy this host. Keep private signing keys
only in the authorized local/CI signing store, outside the Worker and R2. The
public Sparkle key belongs in the app. The host serves publisher-authored feed
bytes; it does not create or sign feeds and does not validate their contents.

Use a fresh bounded version directory and safe asset names, for example
`releases/0.1.0-beta.1/OpenCove-0.1.0-beta.1.zip`. Enclosure URLs must use the exact
HTTPS host, point to the immutable archive key, and contain the actual byte
length and Sparkle EdDSA signature from the other implementation agent's signing
CLI. Check version/build ordering and the minimum macOS version against the
packaged app. A detached archive signature and SHA-256 file are public data;
they do not replace the `sparkle:edSignature` enclosure attribute or app signing.

Publish in this order:

1. Validate the final signed/notarized archive locally. Compute SHA-256 and run
   the approved Sparkle signature tool against those final bytes. Review the
   generated feed locally. Do not change the archive after signing.
2. Upload the archive, detached public signature if used, and checksum **first**
   through authenticated `wrangler r2 object put ... --remote --file ...`.
   Never replace an existing immutable key. All shell file variables below must
   refer to reviewed final files; none is a credential.

   ```sh
   opencove_wrangler r2 object put "opencove-releases/releases/$OPENCOVE_RELEASE_VERSION/$OPENCOVE_ARCHIVE_NAME" \
     --remote --file "$OPENCOVE_ARCHIVE_FILE" --content-type application/zip
   opencove_wrangler r2 object put "opencove-releases/releases/$OPENCOVE_RELEASE_VERSION/$OPENCOVE_ARCHIVE_NAME.sig" \
     --remote --file "$OPENCOVE_SIGNATURE_FILE" --content-type application/octet-stream
   opencove_wrangler r2 object put "opencove-releases/releases/$OPENCOVE_RELEASE_VERSION/$OPENCOVE_ARCHIVE_NAME.sha256" \
     --remote --file "$OPENCOVE_CHECKSUM_FILE" --content-type text/plain
   ```

   Omit the detached-signature upload if the signing workflow only emits the
   Sparkle enclosure attribute. Use `application/x-apple-diskimage` for a DMG.
   Do not upload app bundles, source trees, private signing data, or logs.
   Wrangler 4.152.0 limits these uploads to 300 MiB (314,572,800 bytes), described
   as about 315 MB in Cloudflare's docs. Stop above that bound; use a separately
   reviewed authenticated multipart workflow.
3. GET every uploaded object through the public HTTPS Worker. Compare archive
   bytes/hash, byte length, expected content type, ETag, HEAD, and one range with
   the local files. Verify signatures with the approved release workflow. Confirm
   a nonexistent archive still returns `404`. Keep copies of the prior feed and
   any detached feed signature before replacing them.
4. If the integrated client uses `/appcast.xml.sig`, upload its matching public
   signature after validating it. Separate feed/signature keys have no atomic
   swap; the client must tolerate a short mismatch window, or use its approved
   atomic/versioned signature design. Do not enable detached feed signatures
   until that client contract is settled. Sparkle's signed enclosure attributes
   do not need this endpoint.
5. Upload `appcast.xml` **last**, only after every referenced archive and public
   sidecar passes the live checks:

   ```sh
   opencove_wrangler r2 object put opencove-releases/appcast.xml \
     --remote --file "$OPENCOVE_APPCAST_FILE" --content-type application/xml \
     --cache-control 'no-store, max-age=0'
   ```

6. GET/HEAD the live feed and compare it byte-for-byte with the approved feed.
   Check `no-store`, current enclosures, signatures, root status, and health.
   Run a real Sparkle update from the previous installed version to the published
   signed version. Source review and host HTTP checks do not replace that gate.

If publication must be rolled back, restore the last approved feed (and matching
feed signature if used) through authenticated Wrangler. Keep referenced archives
available. Removing a first, invalid feed restores the explicit `503` state;
do not replace it with an empty success feed. Worker code rollback and feed
rollback are separate actions. Do not remove the bucket, domain, or old archives
as a routine rollback.

## Primary references

- [Cloudflare: install and pin Wrangler](https://developers.cloudflare.com/workers/wrangler/install-and-update/)
- [Official Wrangler npm release 4.152.0](https://www.npmjs.com/package/wrangler/v/4.152.0)
- [Cloudflare: Wrangler environment variables](https://developers.cloudflare.com/workers/wrangler/system-environment-variables/)
- [Cloudflare: Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)
- [Cloudflare: Worker Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)
- [Cloudflare: R2 Workers API, streams, conditions, and ranges](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)
- [Cloudflare: R2 Wrangler upload/download commands](https://developers.cloudflare.com/r2/reference/wrangler-commands/)
- [Cloudflare: upload methods and Wrangler size limit](https://developers.cloudflare.com/r2/objects/upload-objects/)
