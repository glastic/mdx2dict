# Changelog

All notable changes to this project will be documented in this file.

## 0.1.0 - 2026-11-06

- Initial generic release.
- MDict 2.x parsing (zlib, UTF-8/UTF-16LE, Encrypted bit 1, `@@@LINK`).
- Apple Dictionary XML generation and Dictionary Development Kit integration.
- Base CSS auto-detection plus `--css` / `--css-extra`.
- `entry://` link rewriting to `x-dictionary:r:<entry-id>`.
- Optional image extraction (`--images none|thumb|all`).
- Optional audio extraction (`--audio none|all`) with
  `--audio-exclude` regex filtering and inline `new Audio(...)` playback.
- `@@@LINK` aliases and inflected forms merged into target entry indexes.
- Parallel sanitization and parallel resource extraction.
- Streaming full conversion in batches with bounded memory and progress output.
- `--jobs N` parallelism control (`0` auto, `1` serial).
- `--resources skip|drop|strict` for missing image/audio references.
- Key-block cache for lookup-heavy workflows.
- `--ddk` now fails fast when an explicitly supplied path is invalid.
- Synthetic MDX parser fixtures and parser tests.
- `--clean` work-directory cleanup.
- Unit tests for the HTML sanitizer and a GitHub Actions CI build/test job.
- GitHub Actions release workflow for tagged builds.
- Example CSS overrides in `examples/overrides.css`.
- `--version` and clearer option error messages.
- Explicit `--css` paths now fail fast when the file is missing.
- MIT license.
