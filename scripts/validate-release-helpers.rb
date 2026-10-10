#!/usr/bin/env ruby
# frozen_string_literal: true

Dir.glob(File.join(__dir__, "tests/test_*.rb")).sort.each { |test| require test }
