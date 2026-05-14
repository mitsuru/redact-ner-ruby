# examples/

Runnable example scripts for the `redact_ner` gem.

## Prerequisites

```sh
bundle install
bin/rake compile
```

To get actual PII detections you also need:

1. **An ONNX NER model.** Use
   [`scripts/export_ner_model.py`](https://github.com/censgate/redact/tree/main/scripts)
   from the upstream `censgate/redact` repository to export a HuggingFace
   model. Place `model.onnx`, `tokenizer.json`, and `config.json` in a
   single directory.
2. **The ONNX Runtime shared library.** Download a release matching the
   upstream `ort` version (`2.0.0-rc.12`) from
   <https://github.com/microsoft/onnxruntime/releases> and export:

   ```sh
   export ORT_DYLIB_PATH=/abs/path/to/libonnxruntime.so.1.20.0
   ```

Without these, the examples still run, but the recognizer reports
`available? == false` and `#analyze` returns an empty array — which is
itself useful to see.

## Scripts

### `basic_usage.rb`

Prints recognizer metadata and analyzes a handful of English / Japanese
sample sentences.

```sh
bin/bundle exec ruby examples/basic_usage.rb
# or, with a custom model:
REDACT_NER_MODEL=/path/to/model.onnx bin/bundle exec ruby examples/basic_usage.rb
```

### `check_availability.rb`

Demonstrates the recommended "fail loud" pattern: check `#available?`
right after `from_file` and abort if the model could not be initialized.

```sh
bin/bundle exec ruby examples/check_availability.rb /path/to/model.onnx "Alice met Bob at Initech."
```
