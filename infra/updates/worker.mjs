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
  const headers = new Headers(SECURITY_HEADERS);
  headers.set("Cache-Control", NO_CACHE);
  for (const [name, value] of new Headers(extra)) headers.set(name, value);
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

// Static, independently authored CSS. The landing page alone permits its exact
// SHA-256; keep the digest in sync with the UTF-8 contents of LANDING_STYLE.
const LANDING_STYLE = `
:root {
  color-scheme: light;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  color: #192b29;
  background: #f7f9f6;
  line-height: 1.65;
  -webkit-text-size-adjust: 100%;
  --muted: #52615d;
  --accent: #225c4b;
  --line: #d7dfd7;
}
* { box-sizing: border-box; }
body { margin: 0; }
a { color: var(--accent); text-underline-offset: .2em; }
a:hover { text-decoration-thickness: .14em; }
a:focus-visible, summary:focus-visible, [tabindex="-1"]:focus-visible {
  outline: 3px solid #225c4b;
  outline-offset: 5px;
  border-radius: 4px;
}
::selection { background: #c5e4d5; color: #192b29; }
h1, h2, h3, p, figure { margin: 0; }
h1, h2, h3 { line-height: 1.15; text-wrap: balance; }
p { text-wrap: pretty; }
.wrap { width: min(100% - 3rem, 70rem); margin-inline: auto; }
.skip { position: absolute; top: 1rem; left: 1rem; padding: .75rem 1rem; background: #fff; z-index: 2; transform: translateY(-200%); }
.skip:focus { transform: none; }
.site-header { display: flex; align-items: center; justify-content: space-between; gap: 1rem; padding-block: 1.25rem; border-bottom: 1px solid var(--line); }
.brand { display: inline-flex; align-items: center; gap: .65rem; color: inherit; font-size: 1.125rem; font-weight: 750; text-decoration: none; }
.brand-mark { display: inline-block; width: 1.8rem; height: 1.3rem; background: #192b29; border-radius: .2rem .2rem .75rem .75rem; }
.site-nav { display: flex; flex-wrap: wrap; gap: .25rem 1.25rem; }
.site-nav a, .site-footer a { display: inline-flex; align-items: center; min-height: 2.75rem; }
.site-nav a { color: var(--muted); font-size: .9375rem; text-decoration: none; }
.site-nav a:hover { color: var(--accent); text-decoration: underline; }
.hero { display: grid; grid-template-columns: 1.1fr 1fr; align-items: center; gap: 3.5rem; padding-block: 5rem 4rem; }
.eyebrow { color: var(--accent); font-size: .8125rem; font-weight: 750; letter-spacing: .09em; text-transform: uppercase; }
h1 { max-width: 12ch; margin-block: 1rem 1.5rem; font-size: clamp(2.75rem, 5.5vw, 4.5rem); font-weight: 750; letter-spacing: -.055em; }
.intro { max-width: 33rem; color: var(--muted); font-size: 1.1875rem; }
.download { margin-top: 2rem; scroll-margin-top: 2rem; }
.button { display: inline-flex; align-items: center; justify-content: center; gap: 1rem; min-height: 3.25rem; max-width: 100%; padding: .8rem 1.4rem; border: 1px solid var(--accent); border-radius: .75rem; background: var(--accent); color: #fff; font-weight: 650; text-decoration: none; }
.button:hover { background: #174535; border-color: #174535; text-decoration: underline; }
.release-meta { margin-top: .75rem; font-size: .875rem; color: var(--muted); overflow-wrap: anywhere; }
.requirements { margin-top: .2rem; font-size: .875rem; color: var(--muted); }
.release-note { margin-top: .8rem; font-size: .875rem; color: var(--muted); }
.unavailable { padding: 1.25rem; border: 1px solid var(--line); border-radius: .75rem; background: #fff; }
.unavailable h2 { font-size: 1.125rem; margin-bottom: .5rem; }
.unavailable p { color: var(--muted); }
.unavailable a { display: inline-flex; align-items: center; min-height: 2.75rem; margin-top: .25rem; }
.hero-art { min-width: 0; }
.desktop { position: relative; min-height: 23rem; padding: 0 1.5rem 2rem; overflow: hidden; border: 1px solid #ccd9cd; border-radius: 1.5rem; background: radial-gradient(ellipse at 12% 92%, #a4c9b2, transparent 65%), radial-gradient(ellipse at 95% 12%, #b1c8df, transparent 70%), #e3eade; }
.desktop::before, .desktop::after { content: ""; position: absolute; width: 27rem; height: 17rem; border: 1px solid #c4d4c7; border-radius: 50%; transform: rotate(-24deg); }
.desktop::before { top: 10rem; left: -5rem; }
.desktop::after { top: 13rem; left: -4rem; }
.notch { position: relative; z-index: 1; width: 64%; height: 2.1rem; margin-inline: auto; border-radius: 0 0 1.1rem 1.1rem; background: #17201f; }
.notch::after { content: ""; position: absolute; width: .4rem; height: .4rem; border-radius: 50%; background: #384544; top: .65rem; left: calc(50% - .2rem); }
.media-card { position: relative; z-index: 1; width: min(100%, 21rem); margin: 1.5rem auto 0; padding: 1.25rem; border: 1px solid #45514d; border-radius: 1.4rem; background: #192b29; color: #f7f9f6; box-shadow: 0 1.5rem 3rem #192b2926; }
.media-label { font-size: .75rem; color: #b9d7c6; letter-spacing: .08em; text-transform: uppercase; }
.media-row { display: flex; align-items: center; gap: 1rem; margin-top: 1.1rem; }
.cover { flex: 0 0 3.75rem; height: 3.75rem; border: 1px solid #b4d4c1; border-radius: .8rem; background: repeating-radial-gradient(ellipse at 20% 80%, #b4d4c1 0 .35rem, #6b9d87 .4rem .65rem, #386550 .7rem 1rem); }
.media-title { font-size: 1.125rem; font-weight: 650; line-height: 1.35; }
.media-subtitle { margin-top: .3rem; font-size: .8125rem; color: #c0cfc8; }
.track { height: .2rem; margin-top: 1.35rem; background: #50665b; border-radius: 1rem; }
.track::before { content: ""; display: block; width: 42%; height: 100%; background: #c5e5d2; border-radius: inherit; }
.playback { display: flex; align-items: center; justify-content: center; gap: 1.8rem; height: 2rem; margin-top: .7rem; }
.back, .next { width: .8rem; height: .8rem; border-left: .4rem solid #c0cfc8; border-top: .4rem solid transparent; border-bottom: .4rem solid transparent; }
.back { transform: rotate(180deg); }
.pause { width: .8rem; height: .9rem; border-inline: .25rem solid #f7f9f6; }
.art-caption { padding-top: .8rem; text-align: center; font-size: .75rem; color: var(--muted); }
.principles { display: flex; flex-wrap: wrap; gap: .75rem 2rem; margin: 0; padding: 1.25rem 0; list-style: none; border-block: 1px solid var(--line); color: var(--muted); font-size: .875rem; }
.principles li::before { content: ""; display: inline-block; width: .4rem; height: .4rem; margin-right: .6rem; border-radius: 50%; background: var(--accent); vertical-align: middle; }
.section { padding-block: 4rem; scroll-margin-top: 1rem; }
.section-heading { max-width: 40rem; }
h2 { font-size: clamp(1.75rem, 3vw, 2.35rem); letter-spacing: -.035em; }
.section-heading > p { margin-top: 1rem; color: var(--muted); }
.section-heading > .eyebrow { margin-top: 0; margin-bottom: .75rem; color: var(--accent); }
.features { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 1rem; margin-top: 2rem; }
.feature { min-width: 0; padding: 1.5rem; border: 1px solid var(--line); border-radius: 1rem; background: #fff; }
.feature-number { color: var(--accent); font-size: .8125rem; font-weight: 700; }
h3 { font-size: 1.1875rem; letter-spacing: -.015em; }
.feature h3 { margin-block: 1.4rem .75rem; }
.feature p, .steps p { color: var(--muted); font-size: .9375rem; }
.feature-note { margin-top: 1.25rem; color: var(--muted); font-size: .875rem; }
.setup { display: grid; grid-template-columns: 1fr 1.2fr; gap: 4rem; border-top: 1px solid var(--line); }
.steps { margin: 0; padding-left: 1.5rem; }
.steps li { padding: 0 0 1.6rem .5rem; }
.steps li:last-child { padding-bottom: 0; }
.steps li::marker { color: var(--accent); font-weight: 700; }
.steps h3 { margin-bottom: .5rem; }
.updates { margin-top: 1.75rem; padding: 1.25rem; border: 1px solid var(--line); border-radius: 1rem; background: #eef3ec; }
.updates h3 { font-size: 1rem; margin-bottom: .5rem; }
.updates p { color: var(--muted); font-size: .875rem; }
.updates a { display: inline-flex; align-items: center; min-height: 2.75rem; font-size: .875rem; }
.release-details { margin-bottom: 3rem; border: 1px solid var(--line); border-radius: 1rem; background: #fff; }
summary { min-height: 3.5rem; padding: 1rem 1.25rem; cursor: pointer; color: var(--accent); font-weight: 650; }
.details-body { padding: 0 1.25rem 1.25rem; }
.details-body p { color: var(--muted); font-size: .875rem; }
dl { display: grid; grid-template-columns: 7rem minmax(0, 1fr); gap: .5rem 1rem; margin: 1rem 0; font-size: .875rem; }
dt { color: var(--muted); }
dd { margin: 0; overflow-wrap: anywhere; }
code { font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace; font-size: .8125rem; overflow-wrap: anywhere; }
.site-footer { display: flex; justify-content: space-between; align-items: start; gap: 1rem 2rem; padding-block: 1.5rem 2.5rem; border-top: 1px solid var(--line); color: var(--muted); font-size: .8125rem; }
.site-footer p { padding-block: .65rem; }
.footer-links { display: flex; flex-wrap: wrap; gap: .25rem 1.25rem; }
@media (max-width: 56rem) {
  .hero { gap: 2rem; padding-block: 3.5rem; }
  .desktop { min-height: 21rem; padding-inline: 1rem; }
  .features { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .setup { gap: 2rem; }
}
@media (max-width: 42rem) {
  .wrap { width: calc(100% - 2rem); }
  .site-header { align-items: start; flex-wrap: wrap; gap: .5rem 1.25rem; }
  .site-nav { gap: .25rem 1rem; }
  .hero, .setup { grid-template-columns: minmax(0, 1fr); }
  .hero { padding-block: 2.5rem; gap: 2rem; }
  h1 { font-size: clamp(2.75rem, 11vw, 4rem); }
  .intro { font-size: 1.0625rem; }
  .desktop { min-height: 20rem; }
  .section { padding-block: 3rem; }
  .setup { gap: 2rem; }
  .site-footer { flex-direction: column; }
}
@media (max-width: 28rem) {
  .features { grid-template-columns: minmax(0, 1fr); }
  .button { width: 100%; }
  dl { grid-template-columns: minmax(0, 1fr); gap: .2rem; }
  dd { margin-bottom: .6rem; }
}
@media (forced-colors: active) {
  .button { border-color: ButtonText; }
  .brand-mark, .principles li::before { background: CanvasText; }
  .desktop, .media-card { border-color: CanvasText; }
}
`;
const LANDING_STYLE_SHA256 = "LOpGFfL7qtw8tnV+4nXvft6f4xCTv4jZB08uKdbUdKk=";

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
  const archiveKind = release?.path.endsWith(".dmg") ? "DMG" : "ZIP";
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="OpenCove is an independent, open-source macOS notch app for music, calendar events, a file tray, and everyday tools. Explore the early beta for Mac.">
<meta name="theme-color" content="#f7f9f6">
<title>OpenCove — A little more within reach</title>
<style>${LANDING_STYLE}</style>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="site-header wrap">
  <a class="brand" href="/" aria-label="OpenCove home"><span class="brand-mark" aria-hidden="true"></span>OpenCove</a>
  <nav class="site-nav" aria-label="Main navigation">
    <a href="#features">Features</a>
    <a href="#install">Install</a>
    <a href="https://github.com/SergeSerb2/OpenCove">Source code <span aria-hidden="true">↗</span></a>
  </nav>
</header>
<main id="main" class="wrap" tabindex="-1">
  <section class="hero" aria-labelledby="hero-title">
    <div>
      <p class="eyebrow">Independent. Open source. Made for Mac.</p>
      <h1 id="hero-title">A little more within reach.</h1>
      <p class="intro">Your music, plans, and everyday tools, right at the top of your Mac. OpenCove turns the notch into a useful place to pause, glance, and get things done.</p>
      <div class="download" id="download">
        ${release ? `<a class="button" href="${escaped(release.path)}" download aria-describedby="download-meta download-requirements">Download OpenCove <span aria-hidden="true">↓</span></a>
        <p class="release-meta" id="download-meta">Version ${escaped(release.version)} · ${archiveKind} · ${escaped((release.bytes / (1024 * 1024)).toFixed(1))} MiB</p>
        <p class="requirements" id="download-requirements">macOS 15 or later · Apple silicon and Intel</p>
        <p class="release-note">Developer ID signed and notarized. <a href="#release-details">Download details</a></p>` : `<div class="unavailable">
          <h2>Download not available</h2>
          <p>A verified release download is not available here yet. Please check back later.</p>
          <a href="https://github.com/SergeSerb2/OpenCove/releases">View release information <span aria-hidden="true">↗</span></a>
        </div>`}
        <p class="release-note">Early beta. Feature availability depends on your Mac, macOS version, and media app. <a href="https://github.com/SergeSerb2/OpenCove/blob/main/docs/compatibility.md">Read compatibility notes</a>.</p>
      </div>
    </div>
    <figure class="hero-art">
      <div class="desktop" aria-hidden="true">
        <div class="notch"></div>
        <div class="media-card">
          <div class="media-label">Now Playing</div>
          <div class="media-row"><div class="cover"></div><div><div class="media-title">A moment for music.</div><div class="media-subtitle">Right where you need it.</div></div></div>
          <div class="track"></div>
          <div class="playback"><span class="back"></span><span class="pause"></span><span class="next"></span></div>
        </div>
      </div>
      <figcaption class="art-caption">An illustration of the notch layout.</figcaption>
    </figure>
  </section>
  <ul class="principles" aria-label="At a glance">
    <li>Native macOS app</li>
    <li>MIT licensed</li>
    <li>No account or subscription</li>
    <li>Notch and floating pill layouts</li>
  </ul>
  <section class="section" id="features" aria-labelledby="features-title">
    <div class="section-heading">
      <p class="eyebrow">In the public beta</p>
      <h2 id="features-title">Small space. Everyday uses.</h2>
      <p>Keep the things you reach for close by, then get back to what you were doing.</p>
    </div>
    <div class="features">
      <article class="feature"><span class="feature-number" aria-hidden="true">01 / Music</span><h3>A place for Now Playing</h3><p>See track details and artwork. Use the playback controls that your current media source supports.</p></article>
      <article class="feature"><span class="feature-number" aria-hidden="true">02 / Calendar</span><h3>Your next event, at a glance</h3><p>View upcoming events, meeting links, and countdowns when you enable Calendar access.</p></article>
      <article class="feature"><span class="feature-number" aria-hidden="true">03 / Files</span><h3>Keep files close</h3><p>Drop files into the tray so you can open or share them when you need them.</p></article>
      <article class="feature"><span class="feature-number" aria-hidden="true">04 / Time</span><h3>Make time for a task</h3><p>Set a timer that keeps its deadline when you quit and reopen OpenCove.</p></article>
      <article class="feature"><span class="feature-number" aria-hidden="true">05 / Status</span><h3>Useful system details</h3><p>See volume, brightness, battery, Bluetooth, and Focus information when your Mac makes it available.</p></article>
      <article class="feature"><span class="feature-number" aria-hidden="true">06 / Appearance</span><h3>A fit for your display</h3><p>Use a notch layout or a floating pill. Choose your display, hover behavior, reduced motion, and an optional contrast outline.</p></article>
    </div>
    <p class="feature-note">Optional weather, travel alerts, audio levels, and more are available in Settings. Some features need permission or a supported device or service. <a href="https://github.com/SergeSerb2/OpenCove/blob/main/docs/privacy.md">See permissions and privacy</a>.</p>
  </section>
  <section class="section setup" id="install" aria-labelledby="install-title">
    <div class="section-heading">
      <p class="eyebrow">Get started</p>
      <h2 id="install-title">At home on your Mac.</h2>
      <p>OpenCove runs from your menu bar. Start with the tools you want, and adjust the rest in Settings.</p>
      <aside class="updates" aria-labelledby="updates-title">
        <h3 id="updates-title">Keeping OpenCove up to date</h3>
        <p>${feedPresent
          ? "An update feed is published. In OpenCove, choose Check for Updates… from the menu bar menu or Settings → About. Automatic update checks ask for your consent; automatic downloads can be enabled in Settings."
          : "No update feed has been published here yet. Check this page again for new downloads. In-app update checks need an available update feed."}</p>
        ${feedPresent ? '<a href="/appcast.xml">View update feed <span aria-hidden="true">↗</span></a>' : ""}
      </aside>
    </div>
    <ol class="steps">
      <li><h3>Download and unpack</h3><p>${release
        ? archiveKind === "DMG" ? "Download the disk image above, then double-click it in Downloads to open it." : "Download the ZIP above, then double-click it in Downloads to unpack it."
        : "When a release is available, download it from this page. Open the ZIP or disk image in Downloads."}</p></li>
      <li><h3>Move to Applications</h3><p>Drag OpenCove into your Applications folder, then open it from there. If you already have a copy running, quit it before replacing it.</p></li>
      <li><h3>Make it yours</h3><p>Use the OpenCove menu bar icon to open the panel or Settings. Hover over the notch to expand it; press Escape to close it. Enable optional features and their permissions when you want to use them.</p></li>
    </ol>
  </section>
  ${release ? `<details class="release-details" id="release-details">
    <summary>Download details &amp; checksum</summary>
    <div class="details-body">
      <p>These details describe the published download. The SHA-256 checksum identifies the archive so you can compare it after downloading.</p>
      <dl>
        <dt>Version</dt><dd>${escaped(release.version)}</dd>
        <dt>Format</dt><dd>${archiveKind} archive · universal (Apple silicon and Intel)</dd>
        <dt>Size</dt><dd>${escaped(String(release.bytes))} bytes</dd>
        <dt>Requires</dt><dd>macOS 15 or later</dd>
        <dt>SHA-256</dt><dd><code>${escaped(release.sha256)}</code></dd>
      </dl>
      <p><a href="/release.json">Release metadata</a> · <a href="https://github.com/SergeSerb2/OpenCove/releases">Release information</a></p>
    </div>
  </details>` : ""}
</main>
<footer class="site-footer wrap">
  <p>OpenCove · Independent, open-source software for macOS.</p>
  <nav class="footer-links" aria-label="Project links">
    <a href="https://github.com/SergeSerb2/OpenCove">GitHub</a>
    <a href="https://github.com/SergeSerb2/OpenCove/blob/main/docs/privacy.md">Privacy</a>
    <a href="https://github.com/SergeSerb2/OpenCove/issues">Report an issue</a>
  </nav>
</footer>
</body>
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
      // Reject encoded names and dot segments still visible in Request.url.
      // The runtime can canonicalize literal separators before this handler;
      // canonical paths still pass only the fixed public-route allowlist.
      const rawPath = /^https?:\/\/[^/]+(\/[^?#]*)?/.exec(request.url)?.[1] ?? "/";
      if (/[\\%]/.test(rawPath) || /\/(?:\.|\.\.)(?:\/|$)/.test(rawPath)) return missing(request);
      const path = new URL(request.url).pathname;
      if (path === "/" || path === "/health") {
        const feed = await env.RELEASES.head(FEED);
        const feedPresent = feed !== null && feed.size > 0;
        if (path === "/") {
          return respond(request, page(feedPresent, await publishedRelease(env.RELEASES)), 200, {
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": `${SECURITY_HEADERS["Content-Security-Policy"]}; style-src 'sha256-${LANDING_STYLE_SHA256}'`,
          });
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
