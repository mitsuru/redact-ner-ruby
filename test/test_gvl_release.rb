# frozen_string_literal: true

require "test_helper"

# Proves that native methods which perform CPU-bound work without touching
# Ruby objects release the GVL, so other Ruby threads keep running during the
# native call. We can't drive a real ONNX inference in CI (no model), so we use
# a dedicated test-only native probe, `_nogvl_sleep_ms`, that sleeps inside the
# same `nogvl` helper that wraps inference. If the GVL is held, a background
# thread is starved and its counter barely advances; if it is released, the
# counter climbs into the thousands. The margin is enormous (≈0 vs thousands),
# so the threshold is not flaky.
class TestGvlRelease < Minitest::Test
  def setup
    @rec = RedactNer::Recognizer.from_file("/tmp/no-such-model.onnx")
  end

  def test_nogvl_sleep_lets_other_threads_run
    counter = 0
    running = true
    bg = Thread.new do
      while running
        counter += 1
        Thread.pass
      end
    end
    # Give the background thread a moment to actually start spinning.
    Thread.pass until counter > 0

    @rec._nogvl_sleep_ms(200)

    running = false
    bg.join

    # With the GVL released for 200ms, a tight Ruby loop runs many thousands of
    # iterations. With the GVL held it would be ~0. 100 is a deliberately low,
    # non-flaky floor.
    assert_operator counter, :>, 100,
                    "background thread was starved (#{counter} iters) — GVL not released during native call"
  end
end
