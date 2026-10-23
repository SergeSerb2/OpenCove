// Public reads only. Publication uses authenticated Wrangler outside this Worker.
const FEED = "appcast.xml";
const NO_CACHE = "no-store, max-age=0";
const IMMUTABLE = "public, max-age=31536000, immutable, no-transform";
const RELEASE_PATH = /^\/releases\/([A-Za-z0-9][A-Za-z0-9._-]{0,63})\/([A-Za-z0-9][A-Za-z0-9._-]{0,127})$/;
const SECURITY_HEADERS = {
  "Content-Security-Policy": "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Referrer-Policy": "no-referrer",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=(), display-capture=()",
  "Strict-Transport-Security": "max-age=31536000",
};

function respond(request, body, status = 200, extra = {}) {
  const headers = new Headers({ ...SECURITY_HEADERS, "Cache-Control": NO_CACHE, ...extra });
  return new Response(request.method === "HEAD" ? null : body, { status, headers });
}

function unavailable(request) {
  return respond(request, "Updates are temporarily unavailable.\n", 503, {
    "Content-Type": "text/plain; charset=utf-8",
    "Retry-After": "60",
  });
}

function missing(request) {
  return respond(request, "Not found.\n", 404, { "Content-Type": "text/plain; charset=utf-8" });
}

function escaped(value) {
  return value.replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
}

async function publishedRelease(bucket) {
  const object = await bucket.get("release.json");
  if (object === null || object.size > 4096 || !("body" in object)) return null;
  let release;
  try { release = JSON.parse(await object.text()); } catch { return null; }
  if (release === null || typeof release !== "object" || Array.isArray(release)) return null;
  const match = typeof release.path === "string" && RELEASE_PATH.exec(release.path);
  if (!match || match[1].includes("..") || match[2].includes("..") ||
      !/\.(?:zip|dmg)$/.test(match[2]) || release.version !== match[1] ||
      typeof release.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(release.sha256) ||
      !Number.isSafeInteger(release.bytes) || release.bytes <= 0 ||
      release.architecture !== "universal2" || release.minimumSystemVersion !== "15.0" || release.notarized !== true) return null;
  const archive = await bucket.head(release.path.slice(1));
  if (archive === null || archive.size !== release.bytes) return null;
  return { version: release.version, path: release.path, sha256: release.sha256, bytes: release.bytes,
    architecture: release.architecture, minimumSystemVersion: release.minimumSystemVersion, notarized: true };
}

function page(feedPresent, release) {
  // Only the publisher's strictly validated release descriptor supplies a link.
  return `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenCove downloads and updates</title>
<main>
<h1>OpenCove</h1>
<p>An independent, open-source macOS notch app.</p>
<p>${feedPresent
    ? "An update feed has been published. OpenCove can use it to check for updates."
    : "No update feed has been published here yet."}</p>
${release ? `<p><a href="${escaped(release.path)}" download>Download OpenCove ${escaped(release.version)}</a></p>
<p>macOS 15 or later · Apple Silicon and Intel</p>
<p>SHA-256: <code>${escaped(release.sha256)}</code></p>` : "<p>A signed release download is not available yet.</p>"}
<p><a href="https://github.com/SergeSerb2/OpenCove">Source and build instructions</a></p>
<p><a href="https://github.com/SergeSerb2/OpenCove/releases">Release information</a></p>
${feedPresent ? '<p><a href="/appcast.xml">Update feed</a></p>' : ""}
</main>
</html>\n`;
}

function seconds(date) {
  return Math.floor(date.getTime() / 1000) * 1000;
}

function matchesETag(value, etag, weak = false) {
  return value.split(",").some((part) => {
    const tag = part.trim();
    return tag === "*" || (weak ? tag.replace(/^W\//, "") === etag : tag === etag);
  });
}

function preconditionStatus(headers, object) {
  const modified = seconds(object.uploaded);
  const ifMatch = headers.get("If-Match");
  if (ifMatch !== null) {
    if (!matchesETag(ifMatch, object.httpEtag)) return 412;
  } else {
    const unmodifiedSince = Date.parse(headers.get("If-Unmodified-Since"));
    if (modified > unmodifiedSince) return 412;
  }
  const ifNoneMatch = headers.get("If-None-Match");
  if (ifNoneMatch !== null) {
    if (matchesETag(ifNoneMatch, object.httpEtag, true)) return 304;
  } else {
    const modifiedSince = Date.parse(headers.get("If-Modified-Since"));
    if (modified <= modifiedSince) return 304;
  }
  return null;
}

function requestedRange(request, object) {
  // Range is defined for GET. Ignore malformed or multiple ranges with a full 200.
  if (request.method !== "GET") return null;
  const value = request.headers.get("Range");
  const match = /^bytes=(\d*)-(\d*)$/.exec(value ?? "");
  if (!match || (!match[1] && !match[2])) return null;
  const ifRange = request.headers.get("If-Range");
  if (ifRange !== null && ifRange !== object.httpEtag &&
      !(Date.parse(ifRange) === seconds(object.uploaded))) return null;
  if (object.size === 0) return false;
  if (!match[1]) {
    const length = Math.min(Number(match[2]), object.size);
    return length > 0 ? { offset: object.size - length, length } : false;
  }
  const offset = Number(match[1]);
  const end = match[2] ? Math.min(Number(match[2]), object.size - 1) : object.size - 1;
  if (!Number.isSafeInteger(offset) || offset >= object.size || end < offset) return false;
  return { offset, length: end - offset + 1 };
}

function assetType(asset) {
  if (asset.endsWith(".zip")) return "application/zip";
  if (asset.endsWith(".dmg")) return "application/x-apple-diskimage";
  if (asset.endsWith(".sha256") || asset.endsWith(".txt")) return "text/plain; charset=utf-8";
  return "application/octet-stream";
}

async function serveObject(request, bucket, key, { feed = false, asset = null } = {}) {
  const object = await bucket.head(key);
  if (object === null) return feed ? unavailable(request) : missing(request);
  if (feed && object.size === 0) return unavailable(request);
  const headers = new Headers({
    "Content-Type": feed ? "application/xml; charset=utf-8" : assetType(asset ?? key),
    "Cache-Control": asset ? IMMUTABLE : NO_CACHE,
    "ETag": object.httpEtag,
    "Last-Modified": object.uploaded.toUTCString(),
    "Accept-Ranges": "bytes",
  });
  if (asset) headers.set("Content-Disposition", `attachment; filename="${asset}"`);
  const condition = preconditionStatus(request.headers, object);
  if (condition !== null) {
    if (condition === 412) headers.set("Cache-Control", NO_CACHE);
    return respond(request, null, condition, Object.fromEntries(headers));
  }
  const range = requestedRange(request, object);
  if (range === false) {
    headers.set("Content-Range", `bytes */${object.size}`);
    headers.set("Cache-Control", NO_CACHE);
    headers.set("Content-Length", "0");
    return respond(request, null, 416, Object.fromEntries(headers));
  }
  headers.set("Content-Length", String(range ? range.length : object.size));
  if (range) {
    headers.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${object.size}`);
  }
  if (request.method === "HEAD") return respond(request, null, 200, Object.fromEntries(headers));

  // Tie the stream to the metadata above, including during feed replacement.
  // R2 returns metadata without a body when this official precondition fails.
  const bodyObject = await bucket.get(key, {
    onlyIf: { etagMatches: object.etag },
    ...(range ? { range } : {}),
  });
  if (bodyObject === null) return feed ? unavailable(request) : missing(request);
  if (!("body" in bodyObject) || bodyObject.body === undefined) return unavailable(request);
  return respond(request, bodyObject.body, range ? 206 : 200, Object.fromEntries(headers));
}

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return respond(request, "Method not allowed.\n", 405, {
        "Allow": "GET, HEAD",
        "Content-Type": "text/plain; charset=utf-8",
      });
    }
    try {
      // Reject encoded names and dot segments before URL normalizes its pathname.
      const rawPath = /^https?:\/\/[^/]+(\/[^?#]*)?/.exec(request.url)?.[1] ?? "/";
      if (/[\\%]/.test(rawPath) || /\/(?:\.|\.\.)(?:\/|$)/.test(rawPath)) return missing(request);
      const path = new URL(request.url).pathname;
      if (path === "/" || path === "/health") {
        const feed = await env.RELEASES.head(FEED);
        const feedPresent = feed !== null && feed.size > 0;
        if (path === "/") {
          return respond(request, page(feedPresent, await publishedRelease(env.RELEASES)), 200, { "Content-Type": "text/html; charset=utf-8" });
        }
        return respond(request, JSON.stringify({
          status: feedPresent ? "feed-present" : "awaiting-release",
          feedPresent,
        }) + "\n", feedPresent ? 200 : 503, {
          "Content-Type": "application/json; charset=utf-8",
          ...(feedPresent ? {} : { "Retry-After": "60" }),
        });
      }
      if (path === "/appcast.xml") return await serveObject(request, env.RELEASES, FEED, { feed: true });
      if (path === "/download" || path === "/release.json") {
        const release = await publishedRelease(env.RELEASES);
        if (release === null) return unavailable(request);
        if (path === "/download") return respond(request, null, 302, { "Location": release.path });
        return respond(request, JSON.stringify(release) + "\n", 200, { "Content-Type": "application/json; charset=utf-8" });
      }
      if (path === "/appcast.xml.sig") return await serveObject(request, env.RELEASES, "appcast.xml.sig");
      const release = RELEASE_PATH.exec(path);
      if (release && !release[1].includes("..") && !release[2].includes("..")) {
        return await serveObject(request, env.RELEASES, path.slice(1), { asset: release[2] });
      }
      return missing(request);
    } catch {
      // Never return storage errors, credentials, account data, or request values.
      return unavailable(request);
    }
  },
};
