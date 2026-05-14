# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rb_sys/extensiontask"

GEMSPEC = Gem::Specification.load("redact_ner.gemspec")

RbSys::ExtensionTask.new("redact_ner", GEMSPEC) do |ext|
  ext.lib_dir = "lib/redact_ner"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

task default: %i[compile test]
