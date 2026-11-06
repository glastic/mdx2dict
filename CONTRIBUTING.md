# Contributing

Thanks for improving mdx2dict.

## Requirements

- macOS 13+
- Xcode or Command Line Tools
- Apple *Additional Tools for Xcode* (Dictionary Development Kit) only for
  end-to-end conversions. Unit tests and `swift build` do not need it.

## Build and test

```bash
swift build
swift build -c release
swift test
```

## Guidelines

- Keep the core dictionary-agnostic. Dictionary-specific selectors, tag names,
  or path conventions belong in CSS supplied through `--css` / `--css-extra`,
  not in Swift code.
- Do not add test fixtures containing copyrighted dictionary content. Use small
  synthetic HTML/MDX fixtures.
- Do not commit `/.build`, `/build`, generated `.dictionary` bundles, or
  dictionary files.
- Keep CLI behavior backward compatible when possible; document new flags in
  `README.md` and add an entry to `CHANGELOG.md`.
- Prefer small, focused pull requests with a clear description and manual test
  steps.

## Reporting issues

Please include:

- macOS version and Swift version (`swift --version`)
- the command used
- the stage that failed (collect / sanitize / DDK build / install)
- relevant log output, without dictionary content or credentials

For conversion problems, a minimal synthetic HTML sample is much more useful
than a full dictionary file.

## License

By contributing, you agree that your contributions are licensed under the MIT
License (see `LICENSE`).
