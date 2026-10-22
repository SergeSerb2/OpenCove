# Contributing

OpenCove is an early beta. Small fixes with real reproduction steps are useful.

1. Check [existing issues](https://github.com/SergeSerb2/OpenCove/issues) and [compatibility](docs/compatibility.md).
2. Build with [the documented toolchain](docs/building.md). Use separate output and data directories; do not overwrite a running app.
3. Explain the problem, the resulting behavior, and how you checked it through the real app, API, CLI, or device. Include an empty or failure case when practical. State checks you could not run.
4. Open a [pull request](https://github.com/SergeSerb2/OpenCove/compare). Keep it focused. Do not include build products, tokens, local settings, calendar/notification contents, private reference material, or signing keys.

Do not add unit tests or mocked services. Do not automate desktop input, hardware keys, or lock events. End-to-end checks must use real interfaces and isolated app data. Request privacy access only when the person running a manual check has explicitly chosen it.

Use independently written source and original or clearly licensed assets. Do not contribute proprietary code, extracted implementation, copied artwork, private binaries, or license bypasses. Preserve MIT notices. Contributions are accepted under the project's [MIT license](LICENSE).

Use [private security reporting](SECURITY.md) for sensitive defects. Follow the [code of conduct](CODE_OF_CONDUCT.md). CI compiles and validates packaging; it does not certify hardware, permission, or secure-screen behavior.
