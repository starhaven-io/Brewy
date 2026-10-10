#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "rexml/document"
require_relative "lib/xml-text"

module XCResultJUnit
  DURATION = /([\d.]+)\s*(ms|s|m|h)/
  UNITS = { "s" => 1, "m" => 60, "h" => 3600 }.freeze

  module_function

  def parse_duration(raw)
    raw.to_s.scan(DURATION).reduce(0.0) do |total, (value, unit)|
      value += "0" if /\A\d+\.\z/.match?(value)
      seconds = unit == "ms" ? Float(value) / 1000 : Float(value) * UNITS.fetch(unit)
      total + seconds
    end
  end

  def format_duration(seconds)
    return format("%.3f", seconds).downcase unless seconds.finite?

    # Round the exact binary value, matching Python's fixed-point formatting.
    milliseconds = (seconds.to_r * 1000).round(half: :even)
    whole, fraction = milliseconds.divmod(1000)
    "#{whole}.#{format('%03d', fraction)}"
  end

  def collect_failure_messages(node)
    (node["children"] || []).flat_map do |child|
      message = child["nodeType"] == "Failure Message" ? XMLText.clean(child["name"]) : ""
      [*(message.empty? ? [] : [message]), *collect_failure_messages(child)]
    end
  end

  def walk_tests(node, suite = nil, &block)
    return yield(suite.nil? || suite.empty? ? "Unknown" : suite, node) if node["nodeType"] == "Test Case"

    if ["Test Suite", "Test Bundle"].include?(node["nodeType"])
      name = node.fetch("name", "")
      if suite.nil?
        suite = XMLText.clean(name) unless name.nil?
      else
        # Preserve the original converter's label for an explicitly null nested name.
        suite = "#{suite}.#{name.nil? ? 'None' : XMLText.clean(name)}"
      end
    end
    (node["children"] || []).each { |child| walk_tests(child, suite, &block) }
  end

  def convert(data)
    suites = {}
    (data["testNodes"] || []).each do |plan|
      walk_tests(plan) { |suite, test| (suites[suite] ||= []) << test }
    end
    document = REXML::Document.new
    document << REXML::XMLDecl.new("1.0", "UTF-8")
    root = document.add_element("testsuites")
    suites.each do |name, tests|
      suite = root.add_element("testsuite", {
        "name" => name, "tests" => tests.length.to_s,
        "failures" => tests.count { |test| test["result"] == "Failed" }.to_s,
        "skipped" => tests.count { |test| test["result"] == "Skipped" }.to_s,
        "time" => format_duration(tests.sum { |test| parse_duration(test["duration"]) })
      })
      tests.each do |test|
        testcase = suite.add_element("testcase", "name" => XMLText.clean(test["name"]), "classname" => name,
                                    "time" => format_duration(parse_duration(test["duration"])))
        case test["result"]
        when "Failed"
          messages = collect_failure_messages(test)
          testcase.add_element("failure", "message" => messages.first || "Test failed").text = messages.empty? ? "Failed" : messages.join("\n")
        when "Skipped"
          testcase.add_element("skipped")
        end
      end
    end
    # XML parsers normalize literal attribute whitespace; preserve it as character references.
    REXML::XPath.each(document, "//*") do |element|
      element.attributes.each_attribute do |attribute|
        attribute.normalized = attribute.to_s.gsub(/[\t\n\r]/, "\t" => "&#9;", "\n" => "&#10;", "\r" => "&#13;")
      end
    end
    output = +""
    # The default formatter preserves failure-message whitespace exactly.
    REXML::Formatters::Default.new.write(document, output)
    output
  end

  def main(arguments)
    if arguments.length != 1
      warn "usage: xcresult-to-junit.rb <xcresult>"
      return 2
    end
    stdout, stderr, status = Open3.capture3("xcrun", "xcresulttool", "get", "test-results", "tests", "--path", arguments.first)
    abort stderr unless status.success?

    puts convert(JSON.parse(stdout.force_encoding(Encoding::UTF_8)))
    0
  end
end

exit XCResultJUnit.main(ARGV) if $PROGRAM_NAME == __FILE__
