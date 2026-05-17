# redact_ner

Ruby bindings for the [`redact-ner`](https://crates.io/crates/redact-ner) Rust
crate. Provides Named Entity Recognition (NER) for PII detection backed by the
ONNX Runtime.

## Status

Early MVP. Wraps the upstream `NerRecognizer` API surface:
`from_file`, `analyze`, `available?`, `supports_language?`,
`supported_entities`, plus configuration accessors.

## Installation

The gem ships a native Rust extension built via
[`rb_sys`](https://github.com/oxidize-rb/rb-sys). You need:

- Ruby >= 3.0
- A working Rust toolchain (`rustc` and `cargo`, stable)
- The ONNX Runtime shared library available at runtime (see below)

```sh
bundle install
bin/rake compile   # or: bundle exec rake compile
```

> **Note**: invoke rake via `bin/rake` (a bundler binstub) or `bundle exec
> rake`. Running plain `rake` will fail because the globally installed rake
> conflicts with the bundle-locked version.

### Precompiled musl gems (Alpine / distroless)

The precompiled `x86_64-linux-musl` and `aarch64-linux-musl` gems link the C++
runtime `libstdc++` dynamically, so it must be present at load time. Bare
Alpine/distroless images do not ship it — install it first, e.g. `apk add
--no-cache libstdc++` on Alpine. glibc images (e.g. Debian slim) already
include it.

### ONNX Runtime

`redact-ner` uses the `ort` crate with the `load-dynamic` feature, which means
the ONNX Runtime shared library is looked up at runtime, not at link time. You
must point `ORT_DYLIB_PATH` to a `libonnxruntime.so` / `.dylib` / `.dll`
compatible with the upstream crate.

Example (Linux):

```sh
export ORT_DYLIB_PATH=/path/to/onnxruntime-linux-x64-1.20.0/lib/libonnxruntime.so.1.20.0
```

### Graceful fallback — important

Upstream `redact-ner` does **not** raise when a model or tokenizer cannot be
loaded. `Recognizer.from_file` always returns a recognizer object; if the ONNX
session or tokenizer fails to initialize (model file missing, `ORT_DYLIB_PATH`
unset, etc.), the recognizer is left in an "unavailable" state and
`#analyze` quietly returns an empty array.

If you want a hard failure instead, check `#available?` immediately:

```ruby
rec = RedactNer::Recognizer.from_file("model.onnx")
raise "NER model failed to load" unless rec.available?
```

## Usage

```ruby
require "redact_ner"

recognizer = RedactNer::Recognizer.from_file("path/to/model.onnx")

results = recognizer.analyze("John Doe works at Acme Corp in New York", "en")
results.each do |r|
  puts "#{r.entity_type}\t#{r.start}..#{r.end}\t#{r.score.round(3)}\t#{r.text}"
end
```

`analyze` returns an array of `RedactNer::Result`, which is a `Struct` with the
following attributes:

| Attribute         | Type    | Notes                                         |
|-------------------|---------|-----------------------------------------------|
| `entity_type`     | String  | e.g. `"PERSON"`, `"ORGANIZATION"`, `"LOCATION"` |
| `start`           | Integer | byte offset, inclusive                        |
| `end`             | Integer | byte offset, exclusive                        |
| `score`           | Float   | model confidence in `[0.0, 1.0]`              |
| `recognizer_name` | String  | always `"NerRecognizer"`                      |
| `text`            | String  | the matched substring                         |

Other methods:

```ruby
recognizer.available?              # => true if a model + tokenizer were loaded
recognizer.supports_language?("ja") # => true / false
recognizer.supported_entities      # => ["PERSON", "LOCATION", ...]
recognizer.name                    # => "NerRecognizer"
recognizer.min_confidence          # => 0.7
recognizer.max_seq_length          # => 512
recognizer.model_path              # => the path you passed in
```

## Model files

This gem does not bundle models. Use the
[`scripts/export_ner_model.py`](https://github.com/censgate/redact/tree/main/scripts)
helper from the upstream `censgate/redact` repository to export a HuggingFace
NER model to ONNX. Place the resulting `model.onnx`, `tokenizer.json`, and
`config.json` in a single directory and pass the `.onnx` path to
`Recognizer.from_file`.

## Development

```sh
bundle install
bin/rake compile
bin/rake test
```

## Releasing

Releases are automated. To cut a release:

1. Run the **Release Prep** workflow (Actions → Release Prep → Run workflow),
   choosing the `bump` level (`patch`/`minor`/`major`). It bumps
   `lib/redact_ner/version.rb`, rolls `CHANGELOG.md` from GitHub-generated
   notes, opens a **Release PR**, and creates a **draft GitHub Release**.
2. Review/edit the Release PR (and the draft Release notes) and **merge** it.
   Merging auto-creates and pushes the `vX.Y.Z` tag.
3. The tag triggers the **Release** workflow: it builds the 5 precompiled
   gems + source gem, then the `publish` job waits for approval on the
   `rubygems` GitHub Environment. Approve it to publish to RubyGems and
   un-draft the GitHub Release with the gem assets attached.

To abort before publishing, close the Release PR without merging and delete
the `release/vX.Y.Z` branch and the draft Release.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. The upstream `redact-ner` crate is Apache-2.0.
