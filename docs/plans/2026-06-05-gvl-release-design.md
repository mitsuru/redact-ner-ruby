# GVL Release During ONNX Inference — Design

Date: 2026-06-05
Issue: redact-ner-ruby-dxb

## Problem

`RbRecognizer::analyze_raw` held Ruby's Global VM Lock (GVL) across
`self.inner.analyze(...)`, which runs ONNX `Session::run` — a CPU-bound call
that touches no Ruby objects. While it ran, every other Ruby thread in the
process was blocked. A multi-threaded Ruby app (e.g. Puma) could not overlap
NER inference with any other work.

## Approach

Release the GVL for the duration of inference, then re-acquire it to build the
Ruby `Array`. magnus 0.8 does not expose a `without_gvl` wrapper, so we call
`rb_sys::rb_thread_call_without_gvl` directly through a small, self-owned
`unsafe` helper.

Rejected alternative: the `lucchetto` crate (the only dedicated `#[without_gvl]`
crate). Its author explicitly states it is not production-ready ("may contain
memory bugs… may be unsafe"), it is effectively unmaintained, and its rb-sys
compatibility is unstated. Unacceptable risk for a gem with a 5-platform
precompiled release pipeline.

## Dependency

```toml
rb-sys = { version = ">=0.9.113", default-features = false }
```

rb-sys is already in the tree transitively via magnus. `default-features = false`
adds no features, so Cargo's resolved feature set stays identical to magnus's —
no ABI drift. Confirmed: the only `Cargo.lock` change is adding `rb-sys` to the
`redact_ner` package's dependency list; no new transitive crates, no version
change. `rb_thread_call_without_gvl` is in the base bindings (not feature-gated).

## The `nogvl` helper

`fn nogvl<F, R>(f: F) -> R where F: FnOnce() -> R`

- `f` runs synchronously on the **same OS thread** (the C call blocks until it
  returns), so borrows captured by `f` stay valid and no `Send` bound is needed.
- A boxed `Data { func, result }` is passed as `void*`; an `extern "C"`
  trampoline runs `f` and stores the result.
- Panics are caught (`catch_unwind` + `AssertUnwindSafe`) and resumed **after**
  the GVL is re-acquired — never unwind across the C boundary.
- NULL unblock function (ubf): the native call is not interruptible by
  `Thread#kill`/`Timeout`. Accepted — ONNX inference has no clean cancellation
  point; interrupts are deferred until the GVL is re-acquired.

### Safety contract

`f` MUST NOT touch any Ruby object or call any Ruby API while the GVL is
released. In `analyze_raw`, inference runs inside `nogvl`; the `RArray` is built
afterward with the GVL held. `analyze` returns only Rust types
(`Vec<RecognizerResult>`), and concurrent calls are serialized by the
recognizer's internal `Mutex<Session>`, so this holds.

## Testing

GVL release is invisible to correctness, so the existing suite (results
unchanged, unavailable→empty, metadata) stays green either way and does **not**
prove the feature. We add a deterministic red-green probe:

- A test-only native method `_nogvl_sleep_ms(ms)` sleeps inside the same
  `nogvl` helper (leading underscore = not public API).
- `test/test_gvl_release.rb` spins a background Ruby thread incrementing a
  counter, calls `_nogvl_sleep_ms(200)`, and asserts the counter advanced.

Measured margin: GVL held → 1 iteration; GVL released → ~115,000,000. The
`> 100` floor is not flaky. Verified RED (helper sleeping without `nogvl`:
counter = 1) then GREEN (wrapped in `nogvl`).

## Out of scope / follow-up

Confirm the 5-platform cross build before release (not before merge). rb-sys is
already in-tree and `rb_thread_call_without_gvl` is standard Ruby C API, so
cross-compile risk is low.
