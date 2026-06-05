# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.3] - 2026-06-05

## What's Changed
* feat: release GVL during ONNX inference by @mitsuru in https://github.com/mitsuru/redact-ner-ruby/pull/7


**Full Changelog**: https://github.com/mitsuru/redact-ner-ruby/compare/v0.1.2...v0.1.3


## [0.1.2] - 2026-05-17

## What's Changed
* Automate release prep: version bump, CHANGELOG, draft GitHub Release by @mitsuru in https://github.com/mitsuru/redact-ner-ruby/pull/1
* Use a GitHub App token instead of RELEASE_PAT for release automation by @mitsuru in https://github.com/mitsuru/redact-ner-ruby/pull/2

## New Contributors
* @mitsuru made their first contribution in https://github.com/mitsuru/redact-ner-ruby/pull/1

**Full Changelog**: https://github.com/mitsuru/redact-ner-ruby/compare/v0.1.1...v0.1.2


## [0.1.1] - 2026-05-17

### Changed

- Relicensed from BUSL-1.1 to dual **MIT OR Apache-2.0**. The BUSL-1.1 in
  0.1.0 was an unintended leftover; 0.1.0 is superseded and yanked.

## [0.1.0] - 2026-05-17

### Added

- Initial release.
- Ruby bindings for the `redact-ner` Rust crate (`NerRecognizer`) via
  [magnus](https://github.com/matsadler/magnus) + [rb-sys](https://github.com/oxidize-rb/rb-sys).
- `RedactNer::Recognizer.from_file` constructor.
- `#analyze(text, language)` returning `Array<RedactNer::Result>`.
- `#available?`, `#supports_language?`, `#name`, `#supported_entities`,
  `#min_confidence`, `#max_seq_length`, `#model_path` accessors.
- `RedactNer::Result` value object with `entity_type`, `start`, `end`,
  `score`, `recognizer_name`, `text`, `#length`, and `#to_h`.
- Examples: basic usage, fail-loud availability check, integration with
  the [`onnxruntime`](https://github.com/ankane/onnxruntime-ruby) gem,
  and an email regex merge demonstration.
- Precompiled native gems (Ruby 3.2–3.4) for `x86_64-linux`, `aarch64-linux`,
  `x86_64-linux-musl`, `aarch64-linux-musl`, and `x64-mingw-ucrt`, so these
  platforms install without a Rust toolchain. Built and published via GitHub
  Actions (`oxidize-rb/actions/cross-gem` + RubyGems Trusted Publishing).
  - macOS (`*-darwin`), Ruby 4.0, and any other platform install from the
    source gem, which compiles the Rust extension (needs a Rust toolchain;
    macOS also needs the Xcode command-line tools).
  - The precompiled musl gems (Alpine / distroless) link `libstdc++`
    dynamically; install it at runtime, e.g. `apk add --no-cache libstdc++`.

[Unreleased]: https://github.com/mitsuru/redact-ner-ruby/compare/v0.1.3...HEAD
[0.1.1]: https://github.com/mitsuru/redact-ner-ruby/releases/tag/v0.1.1
[0.1.0]: https://github.com/mitsuru/redact-ner-ruby/releases/tag/v0.1.0
[0.1.2]: https://github.com/mitsuru/redact-ner-ruby/releases/tag/v0.1.2
[0.1.3]: https://github.com/mitsuru/redact-ner-ruby/releases/tag/v0.1.3
