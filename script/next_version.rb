#!/usr/bin/env ruby
# frozen_string_literal: true
# Usage: next_version.rb <current X.Y.Z> <patch|minor|major>  -> prints next version
cur, bump = ARGV
abort "usage: next_version.rb X.Y.Z patch|minor|major" unless cur && bump
m = cur.match(/\A(\d+)\.(\d+)\.(\d+)\z/)
abort "invalid version: #{cur}" unless m
major, minor, patch = m.captures.map(&:to_i)
case bump
when "major" then major += 1; minor = 0; patch = 0
when "minor" then minor += 1; patch = 0
when "patch" then patch += 1
else abort "invalid bump: #{bump}"
end
puts "#{major}.#{minor}.#{patch}"
