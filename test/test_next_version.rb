# frozen_string_literal: true
require "minitest/autorun"

class TestNextVersion < Minitest::Test
  def nv(cur, bump)
    `ruby #{File.expand_path("../script/next_version.rb", __dir__)} #{cur} #{bump}`.strip
  end

  def test_patch; assert_equal "0.1.2", nv("0.1.1", "patch"); end
  def test_minor; assert_equal "0.2.0", nv("0.1.1", "minor"); end
  def test_major; assert_equal "1.0.0", nv("0.1.1", "major"); end
  def test_patch_rollover; assert_equal "0.2.10", nv("0.2.9", "patch"); end
  def test_invalid_bump
    out = `ruby #{File.expand_path("../script/next_version.rb", __dir__)} 0.1.1 nope 2>&1`
    refute_equal 0, $?.exitstatus
    assert_match(/invalid bump/, out)
  end
end
