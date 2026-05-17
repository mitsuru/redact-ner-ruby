# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rb_sys/extensiontask"

GEMSPEC = Gem::Specification.load("redact_ner.gemspec")

CROSS_PLATFORMS = %w[
  x86_64-linux
  aarch64-linux
  x86_64-linux-musl
  aarch64-linux-musl
  x86_64-darwin
  arm64-darwin
  x64-mingw-ucrt
].freeze

RbSys::ExtensionTask.new("redact_ner", GEMSPEC) do |ext|
  ext.lib_dir = "lib/redact_ner"
  ext.cross_compile = true
  ext.cross_platform = CROSS_PLATFORMS
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

task default: %i[compile test]
