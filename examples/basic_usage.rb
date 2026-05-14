#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Basic usage example for the redact_ner gem.
#
# Run with:
#   bin/bundle exec ruby examples/basic_usage.rb
#
# Optional environment variables:
#   REDACT_NER_MODEL  Path to the ONNX model file. Defaults to
#                     "models/model.onnx" relative to the gem root.
#   ORT_DYLIB_PATH    Path to libonnxruntime.{so,dylib,dll}. Required at
#                     runtime by the `ort` crate.

require "bundler/setup"
require "redact_ner"

MODEL_PATH = ENV.fetch("REDACT_NER_MODEL", File.expand_path("../models/model.onnx", __dir__))

recognizer = RedactNer::Recognizer.from_file(MODEL_PATH)

puts "=== Recognizer metadata ==="
puts "name              : #{recognizer.name}"
puts "available?        : #{recognizer.available?}"
puts "model_path        : #{recognizer.model_path}"
puts "min_confidence    : #{recognizer.min_confidence}"
puts "max_seq_length    : #{recognizer.max_seq_length}"
puts "supported_entities: #{recognizer.supported_entities.join(", ")}"
puts

unless recognizer.available?
  reasons = []
  reasons << "model file does not exist at #{MODEL_PATH}" unless File.exist?(MODEL_PATH)
  reasons << "ORT_DYLIB_PATH is not set" if ENV["ORT_DYLIB_PATH"].to_s.empty?
  reasons << "tokenizer.json missing next to the model" if File.exist?(MODEL_PATH) &&
                                                          !File.exist?(File.join(File.dirname(MODEL_PATH), "tokenizer.json"))

  warn "Recognizer is not available. Likely reasons:"
  reasons.each { |r| warn "  - #{r}" }
  warn ""
  warn "See README.md for instructions on exporting an ONNX model and"
  warn "configuring the ONNX Runtime shared library."
  warn ""
  warn "analyze() will quietly return [] in this state — continuing the demo"
  warn "to show the fallback behavior."
  puts
end

SAMPLES = [
  ["en", "John Doe works at Acme Corp in New York."],
  ["en", "Contact Maria Garcia at Globex Corporation in Berlin."],
  ["en", "Dr. Watson visited Sherlock Holmes at 221B Baker Street."],
  ["ja", "山田太郎さんは東京のソニー株式会社で働いています。"]
].freeze

SAMPLES.each do |language, text|
  puts "=== [#{language}] #{text}"
  results = recognizer.analyze(text, language)

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
