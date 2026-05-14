use magnus::{function, method, prelude::*, Error, RArray, Ruby};
use redact_core::Recognizer as _;
use redact_ner::NerRecognizer;

#[magnus::wrap(class = "RedactNer::Recognizer", free_immediately, size)]
struct RbRecognizer {
    inner: NerRecognizer,
}

fn runtime_error<E: std::fmt::Display>(e: E) -> Error {
    let ruby = Ruby::get().expect("ruby thread");
    Error::new(ruby.exception_runtime_error(), e.to_string())
}

fn entity_type_to_string(entity_type: &redact_core::EntityType) -> String {
    match entity_type {
        redact_core::EntityType::Custom(name) => name.clone(),
        other => other.as_str().to_string(),
    }
}

impl RbRecognizer {
    fn from_file(path: String) -> Result<Self, Error> {
        let recognizer = NerRecognizer::from_file(&path).map_err(runtime_error)?;
        Ok(Self { inner: recognizer })
    }

    fn analyze_raw(&self, text: String, language: String) -> Result<RArray, Error> {
        let ruby = Ruby::get().map_err(runtime_error)?;
        let results = self.inner.analyze(&text, &language).map_err(runtime_error)?;

        let arr = ruby.ary_new_capa(results.len());
        for r in results {
            let hash = ruby.hash_new();

            hash.aset(
                ruby.to_symbol("entity_type"),
                entity_type_to_string(&r.entity_type),
            )?;
            hash.aset(ruby.to_symbol("start"), r.start)?;
            hash.aset(ruby.to_symbol("end"), r.end)?;
            hash.aset(ruby.to_symbol("score"), r.score)?;
            hash.aset(ruby.to_symbol("recognizer_name"), r.recognizer_name.clone())?;

            let resolved_text = r.text.clone().unwrap_or_else(|| {
                let end = r.end.min(text.len());
                let start = r.start.min(end);
                text.get(start..end).unwrap_or("").to_string()
            });
            hash.aset(ruby.to_symbol("text"), resolved_text)?;

            arr.push(hash)?;
        }
        Ok(arr)
    }

    fn is_available(&self) -> bool {
        self.inner.is_available()
    }

    fn supports_language(&self, language: String) -> bool {
        self.inner.supports_language(&language)
    }

    fn name(&self) -> String {
        self.inner.name().to_string()
    }

    fn supported_entities(&self) -> Vec<String> {
        self.inner
            .supported_entities()
            .iter()
            .map(entity_type_to_string)
            .collect()
    }

    fn min_confidence(&self) -> f32 {
        self.inner.config().min_confidence
    }

    fn max_seq_length(&self) -> usize {
        self.inner.config().max_seq_length
    }

    fn model_path(&self) -> String {
        self.inner.config().model_path.clone()
    }
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("RedactNer")?;
    let class = module.define_class("Recognizer", ruby.class_object())?;

    class.define_singleton_method("from_file", function!(RbRecognizer::from_file, 1))?;

    class.define_method("_analyze_raw", method!(RbRecognizer::analyze_raw, 2))?;
    class.define_method("available?", method!(RbRecognizer::is_available, 0))?;
    class.define_method(
        "supports_language?",
        method!(RbRecognizer::supports_language, 1),
    )?;
    class.define_method("name", method!(RbRecognizer::name, 0))?;
    class.define_method(
        "supported_entities",
        method!(RbRecognizer::supported_entities, 0),
    )?;
    class.define_method("min_confidence", method!(RbRecognizer::min_confidence, 0))?;
    class.define_method("max_seq_length", method!(RbRecognizer::max_seq_length, 0))?;
    class.define_method("model_path", method!(RbRecognizer::model_path, 0))?;

    Ok(())
}
