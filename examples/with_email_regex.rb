#!/usr/bin/env ruby
# frozen_string_literal: true
#
# redact_ner only wraps the NER (model-based) recognizer from the upstream
# crate, which recognizes PERSON / ORGANIZATION / LOCATION / DATE_TIME.
#
# The upstream redact-core crate also ships pattern-based recognizers for
# things like EmailAddress, but those are *not* exposed by this gem.
#
# This example shows how to merge a small Ruby-side regex pass for emails
# with the NER results, returning a single sorted list of detections.
#
# Run with:
#   bin/bundle exec ruby examples/with_email_regex.rb [model.onnx]

require "bundler/setup"
require "onnxruntime"
ENV["ORT_DYLIB_PATH"] ||= OnnxRuntime.ffi_lib.first
require "redact_ner"

MODEL = ARGV[0] ||
        ENV["REDACT_NER_MODEL"] ||
        File.expand_path("../models/julian-multilingual-ner/model.onnx", __dir__)

recognizer = RedactNer::Recognizer.from_file(MODEL)
abort "Recognizer not available (model: #{MODEL})" unless recognizer.available?

# Pragmatic email matcher. For production use a battle-tested validator —
# RFC 5321/5322 is famously hairy.
EMAIL_REGEX = /\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b/i

def detect_emails(text)
  results = []
  text.scan(EMAIL_REGEX) do
    m = Regexp.last_match
    results << RedactNer::Result.new(
      entity_type: "EMAIL_ADDRESS",
      start: m.begin(0),
      end: m.end(0),
      score: 1.0,
      recognizer_name: "RegexpEmailRecognizer",
      text: m[0]
    )
  end
  results
end

def analyze_with_emails(recognizer, text, language = "en")
  ner = recognizer.analyze(text, language)
  emails = detect_emails(text)
  (ner + emails).sort_by(&:start)
end

SAMPLES = [
  "Contact John Doe at john.doe@acme.com for details.",
  "山田太郎 John taro@example.com",
  "Reach out to Maria Garcia <maria@globex.co.jp> in Berlin."
].freeze

SAMPLES.each do |text|
  puts "=== #{text}"
  analyze_with_emails(recognizer, text).each do |r|
    printf("  %-15s [%3d..%3d]  score=%.3f  text=%p\n",
           r.entity_type, r.start, r.end, r.score, r.text)
  end
  puts
end
