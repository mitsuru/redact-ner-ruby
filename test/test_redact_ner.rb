# frozen_string_literal: true

require "test_helper"
require "tempfile"

class TestRedactNer < Minitest::Test
  def test_version_constant
    refute_nil RedactNer::VERSION
  end

  def test_module_and_classes_loaded
    assert defined?(RedactNer::Recognizer)
    assert defined?(RedactNer::Result)
  end

  def test_from_file_returns_recognizer_even_for_missing_model
    # Upstream NerRecognizer::from_file does a graceful fallback when the
    # model/tokenizer cannot be loaded — it returns a Recognizer whose
    # `available?` is false rather than raising.
    rec = RedactNer::Recognizer.from_file("/does/not/exist/model.onnx")
    refute_nil rec
    refute_predicate rec, :available?
  end

  def test_unavailable_recognizer_returns_empty_results
    rec = RedactNer::Recognizer.from_file("/does/not/exist/model.onnx")
    results = rec.analyze("John Doe works at Acme", "en")
    assert_kind_of Array, results
    assert_empty results
  end

  def test_recognizer_metadata
    rec = RedactNer::Recognizer.from_file("/tmp/no-such-model.onnx")
    assert_equal "NerRecognizer", rec.name
    assert_kind_of Array, rec.supported_entities
    assert_includes rec.supported_entities, "PERSON"
    assert_includes rec.supported_entities, "ORGANIZATION"
    assert_includes rec.supported_entities, "LOCATION"
    assert rec.supports_language?("en")
    assert rec.supports_language?("ja")
    refute rec.supports_language?("xx")
    assert_kind_of Float, rec.min_confidence
    assert_kind_of Integer, rec.max_seq_length
    assert_equal "/tmp/no-such-model.onnx", rec.model_path
  end

  def test_result_struct_attributes
    r = RedactNer::Result.new(
      entity_type: "PERSON",
      start: 0,
      end: 8,
      score: 0.98,
      recognizer_name: "NerRecognizer",
      text: "John Doe"
    )
    assert_equal "PERSON", r.entity_type
    assert_equal "PERSON", r.type
    assert_equal 0, r.start
    assert_equal 8, r.end
    assert_in_delta 0.98, r.score, 0.0001
    assert_equal "NerRecognizer", r.recognizer_name
    assert_equal "John Doe", r.text
    assert_equal 8, r.length
  end

  def test_convenience_module_constructor
    rec = RedactNer.from_file("/tmp/no-such-model.onnx")
    assert_kind_of RedactNer::Recognizer, rec
    refute_predicate rec, :available?
  end
end
