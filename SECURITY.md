# Security reporting

Only the current development line is maintained. OpenCove is beta software; there is no stable-version support or response-time guarantee yet.

For a sensitive issue, use [GitHub private vulnerability reporting](https://github.com/SergeSerb2/OpenCove/security/advisories/new) if the repository offers it. Before public launch, the maintainer must enable this feature. If the private form is unavailable, open a minimal [issue](https://github.com/SergeSerb2/OpenCove/issues/new) asking for a private contact; do not post exploit details, private data, or credentials.

Include the affected version/build, macOS version, architecture, permission state, reproduction steps, and likely impact. Remove calendar details, banner text, paths that identify people, API tokens, and signing material. A small reproduction against an isolated development data directory is preferable.

The opt-in development API can read sensitive app state and make real changes. Its loopback binding is not a replacement for its token. Do not share control URLs, `control.json`, or raw state dumps. See [privacy](docs/privacy.md) for local data and network boundaries.

Use the checked-in [quality workflow](docs/quality.md) for an isolated reproduction. Its default real-app run does not request permissions or write to hardware or a live player. Readiness must match the exact bundle path and source-tree hash, as well as the expected version/build.

Do not use a public issue for an active secret. Revoke an exposed token or key through its provider. OpenCove does not operate a remote account or recovery service.
