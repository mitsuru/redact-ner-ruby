# frozen_string_literal: true

require_relative "redact_ner/version"

begin
  ruby_version = RUBY_VERSION.split(".").take(2).join(".")
  require_relative "redact_ner/#{ruby_version}/redact_ner"
rescue LoadError
  require_relative "redact_ner/redact_ner"
end

module RedactNer
  # Lightweight value object returned by Recognizer#analyze. Avoids forcing
  # callers to remember Hash keys and gives a nicer #inspect.
  Result = Struct.new(
    :entity_type,
    :start,
    :end,
    :score,
    :recognizer_name,
    :text,
    keyword_init: true
  ) do
    alias_method :type, :entity_type

    def length
      self.end - start
    end

    def to_h
      super
    end
  end

  class Recognizer
    # Run NER analysis over +text+ and return an array of {RedactNer::Result}.
    #
    # @param text [String] input text to analyze
    # @param language [String] ISO 639-1 language code (default "en")
    # @return [Array<RedactNer::Result>]
    def analyze(text, language = "en")
      raw = _analyze_raw(text.to_s, language.to_s)
      raw.map { |h| Result.new(**h) }
    end
  end

  class << self
    # Convenience constructor: RedactNer.from_file("model.onnx")
    def from_file(path)
      Recognizer.from_file(path.to_s)
    end
  end
end
