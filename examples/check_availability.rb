#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Demonstrates the recommended pattern for treating a missing or broken
# model as a hard error rather than relying on the upstream graceful
# fallback (which silently returns no detections).
#
# Run with:
#   bin/bundle exec ruby examples/check_availability.rb path/to/model.onnx

require "bundler/setup"
require "redact_ner"

model_path = ARGV[0] || ENV["REDACT_NER_MODEL"]

if model_path.nil? || model_path.empty?
  abort "Usage: #{$PROGRAM_NAME} <path/to/model.onnx>"
end

recognizer = RedactNer::Recognizer.from_file(model_path)

unless recognizer.available?
  abort <<~MSG
    NER recognizer failed to initialize for #{model_path}.

    Common causes:
      * the .onnx file does not exist
      * tokenizer.json is missing from the model directory
      * ORT_DYLIB_PATH is unset, so the ONNX Runtime cannot be loaded

    See the project README for setup instructions.
  MSG
end

puts "Recognizer is ready (model: #{recognizer.model_path})."

text = ARGV[1] || "Alice met Bob at Initech in Springfield."
puts "Analyzing: #{text.inspect}"
recognizer.analyze(text, "en").each do |r|
  puts "  #{r.entity_type.ljust(13)} #{r.text.inspect}  (score=#{r.score.round(3)})"
end
