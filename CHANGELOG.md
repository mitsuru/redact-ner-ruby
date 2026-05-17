# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/mitsuru/redact-ner-ruby/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mitsuru/redact-ner-ruby/releases/tag/v0.1.0
