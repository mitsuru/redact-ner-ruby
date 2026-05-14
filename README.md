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
bundle exec rake compile
```

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
bundle exec rake compile
bundle exec rake test
```

## License

Distributed under the Business Source License 1.1, inheriting from the
upstream `redact-ner` crate. See [LICENSE](LICENSE) for details.
