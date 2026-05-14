# frozen_string_literal: true

require_relative "lib/redact_ner/version"

Gem::Specification.new do |spec|
  spec.name = "redact_ner"
  spec.version = RedactNer::VERSION
  spec.authors = ["Mitsuru Hayasaka"]
  spec.email = ["hayasaka.mitsuru@gmail.com"]

  spec.summary = "Ruby bindings for the redact-ner Rust crate (NER-based PII detection via ONNX)"
  spec.description = <<~DESC
    Ruby bindings for the redact-ner crate, providing Named Entity Recognition
    for PII detection using quantized ONNX models through the ONNX Runtime.
  DESC
  spec.homepage = "https://github.com/hayasaka-mitsuru/redact-ner-ruby"
  spec.license = "BUSL-1.1"
  spec.required_ruby_version = ">= 3.0.0"
  spec.required_rubygems_version = ">= 3.3.11"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rs,toml,lock,rb}",
    "Cargo.toml",
    "Cargo.lock",
    "LICENSE",
    "README.md"
  ]

  spec.require_paths = ["lib"]
  spec.extensions = ["ext/redact_ner/extconf.rb"]

  spec.add_dependency "rb_sys", "~> 0.9"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rake-compiler", "~> 1.3"
  spec.add_development_dependency "minitest", "~> 5.0"
end
