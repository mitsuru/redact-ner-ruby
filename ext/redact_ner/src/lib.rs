use magnus::{function, method, prelude::*, Error, RArray, Ruby};
use redact_core::Recognizer as _;
use redact_ner::NerRecognizer;
use std::os::raw::c_void;

/// Run `f` with the GVL released, then re-acquire it before returning.
///
/// SAFETY CONTRACT: `f` MUST NOT touch any Ruby object or call any Ruby API —
/// no other Ruby C function is safe to call while the GVL is released. It is
/// for pure-Rust, CPU-bound (or sleeping) work only.
///
/// `f` runs synchronously on the *same* OS thread (the call blocks until it
/// returns), so borrows captured by `f` stay valid and no `Send` bound is
/// needed. Panics are caught and resumed after the GVL is re-acquired so we
/// never unwind across the C boundary. No unblock function is passed (NULL
/// ubf), so the native call is not interruptible by Thread#kill/Timeout —
/// acceptable because ONNX inference has no clean cancellation point.
fn nogvl<F, R>(f: F) -> R
where
    F: FnOnce() -> R,
{
    struct Data<F, R> {
        func: Option<F>,
        result: Option<std::thread::Result<R>>,
    }

    unsafe extern "C" fn trampoline<F, R>(arg: *mut c_void) -> *mut c_void
    where
        F: FnOnce() -> R,
    {
        let data = &mut *(arg as *mut Data<F, R>);
        let func = data.func.take().expect("nogvl closure run twice");
        data.result = Some(std::panic::catch_unwind(std::panic::AssertUnwindSafe(func)));
        std::ptr::null_mut()
    }

    let mut data: Data<F, R> = Data {
        func: Some(f),
        result: None,
    };

    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(trampoline::<F, R>),
            &mut data as *mut _ as *mut c_void,
            None,
            std::ptr::null_mut(),
        );
    }

    match data.result.take().expect("nogvl closure did not run") {
        Ok(value) => value,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

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
        // ONNX inference is CPU-bound and touches no Ruby objects, so run it
        // with the GVL released to let other Ruby threads make progress.
        let results = nogvl(|| self.inner.analyze(&text, &language)).map_err(runtime_error)?;

        // Building the Ruby Array below DOES touch Ruby, so it runs with the
        // GVL held (we are back in normal extension context here).
        let ruby = Ruby::get().map_err(runtime_error)?;

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

    // Test-only probe used by test/test_gvl_release.rb to prove the GVL is
    // released during native CPU-bound work. Sleeps inside the same code path
    // that wraps inference. NOT part of the public API (leading underscore).
    fn nogvl_sleep_ms(&self, ms: u64) {
        nogvl(|| std::thread::sleep(std::time::Duration::from_millis(ms)));
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
    class.define_method("_nogvl_sleep_ms", method!(RbRecognizer::nogvl_sleep_ms, 1))?;
    class.define_method("min_confidence", method!(RbRecognizer::min_confidence, 0))?;
    class.define_method("max_seq_length", method!(RbRecognizer::max_seq_length, 0))?;
    class.define_method("model_path", method!(RbRecognizer::model_path, 0))?;

    Ok(())
}
