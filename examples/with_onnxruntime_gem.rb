#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Use the `onnxruntime` gem (ankane/onnxruntime-ruby) to supply
# libonnxruntime.so instead of installing it system-wide.
#
# Run with:
#   bin/bundle exec ruby examples/with_onnxruntime_gem.rb [path/to/model.onnx]

require "bundler/setup"
require "onnxruntime"

# The gem bundles libonnxruntime.so under <gem>/vendor/.
# Tell redact_ner about it via ORT_DYLIB_PATH BEFORE loading the extension.
ENV["ORT_DYLIB_PATH"] ||= OnnxRuntime.ffi_lib.first

puts "Using libonnxruntime from: #{ENV['ORT_DYLIB_PATH']}"
puts "ONNX Runtime version:      #{OnnxRuntime.lib_version}"
puts

require "redact_ner"

model_path = ARGV[0] || ENV["REDACT_NER_MODEL"] ||
             File.expand_path("../models/model.onnx", __dir__)

recognizer = RedactNer::Recognizer.from_file(model_path)

puts "Recognizer available?  : #{recognizer.available?}"
puts "Model path             : #{recognizer.model_path}"
puts

unless recognizer.available?
  warn <<~MSG
    Recognizer reported unavailable. The shared library should be resolved by
    the onnxruntime gem, so the likely cause is a missing model file or
    tokenizer.json. Provide a path to a valid ONNX NER model on the command
    line:

      bin/bundle exec ruby #{$PROGRAM_NAME} /path/to/model.onnx

    See examples/README.md for how to export one.
  MSG
  exit 0
end

samples = [
  "John Doe works at Acme Corp in New York.",
  "Contact Maria Garcia at Globex Corporation in Berlin.",
  "山田太郎 John taro@example.com"
]

samples.each do |text|
  puts "=== #{text}"
  results = recognizer.analyze(text, "en")
  if results.empty?
    puts "  (no entities detected)"
  else
    results.each do |r|
      printf("  %-13s [%3d..%3d]  score=%.3f  text=%p\n",
             r.entity_type, r.start, r.end, r.score, r.text)
    end
  end
  puts
end
