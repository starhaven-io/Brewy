# frozen_string_literal: true

require_relative "test_helper"
require_relative "../xcresult-to-junit"

class XCResultJUnitTests < Minitest::Test
  include HelperTestSupport

  def test_duration_units_and_empty_values
    assert_in_delta 3723.25, XCResultJUnit.parse_duration("1h 2m 3s 250ms"), 0.0001
    assert_equal 1, XCResultJUnit.parse_duration("1.s")
    assert_raises(ArgumentError) { XCResultJUnit.parse_duration("1..s") }
    assert_equal 0, XCResultJUnit.parse_duration(nil)
    assert_equal 0, XCResultJUnit.parse_duration("")
  end

  def test_duration_rounding_matches_exact_binary_values_and_millisecond_division
    { "0.0125s" => "0.013", "0.0625s" => "0.062", "0.1875s" => "0.188",
      "4.5ms" => "0.004", "1002.5ms" => "1.002", "0.1s 0.2s 0.3s" => "0.600",
      "1h 2m 3s 250ms" => "3723.250" }.each do |duration, expected|
      data = { "testNodes" => [{ "nodeType" => "Test Case", "name" => "example", "result" => "Passed", "duration" => duration }] }
      suite = REXML::Document.new(XCResultJUnit.convert(data)).root.elements["testsuite"]
      assert_equal expected, suite.attributes["time"], duration
      assert_equal expected, suite.elements["testcase"].attributes["time"], duration
    end
    assert_equal 0.6000000000000001, XCResultJUnit.parse_duration("0.1s 0.2s 0.3s")
    data = { "testNodes" => [{ "nodeType" => "Test Bundle", "name" => "Suite", "children" => [
      { "nodeType" => "Test Case", "name" => "first", "duration" => "0.01s" },
      { "nodeType" => "Test Case", "name" => "second", "duration" => "0.0025s" }] }] }
    assert_equal "0.013", REXML::Document.new(XCResultJUnit.convert(data)).root.elements["testsuite"].attributes["time"]
  end

  def test_nested_suites_failure_messages_skips_and_escaping
    failed = { "nodeType" => "Test Case", "name" => 'quoted <test> & "value"', "result" => "Failed", "duration" => "1s 250ms",
               "children" => [{ "nodeType" => "Failure Message", "name" => "first <failure> & detail" },
                              { "children" => [{ "nodeType" => "Failure Message", "name" => "line 1\n  line 2" }] }] }
    data = { "testNodes" => [{ "nodeType" => "Test Plan", "children" => [
      { "nodeType" => "Test Bundle", "name" => "BrewyTests", "children" => [
        { "nodeType" => "Test Suite", "name" => "Parsing", "children" => [failed,
          { "nodeType" => "Test Case", "name" => "skipped", "result" => "Skipped" },
          { "nodeType" => "Test Case", "name" => "passed", "result" => "Passed", "duration" => "750ms" }] }] },
      { "nodeType" => "Test Case", "name" => "orphan", "result" => "Failed" }] }] }
    root = REXML::Document.new(XCResultJUnit.convert(data)).root
    suite = root.elements["testsuite"]
    assert_equal "BrewyTests.Parsing", suite.attributes["name"]
    assert_equal "3", suite.attributes["tests"]
    assert_equal "1", suite.attributes["failures"]
    assert_equal "1", suite.attributes["skipped"]
    assert_equal "2.000", suite.attributes["time"]
    assert_equal failed["name"], suite.elements["testcase"].attributes["name"]
    failure = suite.elements["testcase/failure"]
    assert_equal "first <failure> & detail", failure.attributes["message"]
    assert_equal "first <failure> & detail\nline 1\n  line 2", failure.text
    refute_nil suite.elements["testcase[2]/skipped"]
    assert_equal "Unknown", root.elements["testsuite[2]"].attributes["name"]
    assert_equal "Test failed", root.elements["testsuite[2]/testcase/failure"].attributes["message"]
    assert_equal "Failed", root.elements["testsuite[2]/testcase/failure"].text
    assert_empty REXML::Document.new(XCResultJUnit.convert({})).root.elements.to_a
  end

  def test_attribute_whitespace_is_preserved_for_xml_consumers
    data = { "testNodes" => [{ "nodeType" => "Test Case", "name" => "a\tb\nc\r", "result" => "Failed",
                              "children" => [{ "nodeType" => "Failure Message", "name" => "first\nsecond" }] }] }
    xml = XCResultJUnit.convert(data)
    assert_includes xml, "a&#9;b&#10;c&#13;"
    assert_includes xml, "first&#10;second"
    assert_equal "a\tb\nc\r", REXML::Document.new(xml).root.elements["testsuite/testcase"].attributes["name"]
  end

  def test_cli_passes_bundle_path_as_one_argument_and_propagates_xcrun_failure
    Dir.mktmpdir("brewy-xcresult-test-") do |directory|
      bin = Pathname(directory)
      write_executable(bin / "xcrun", <<~'SH')
        #!/bin/sh
        printf '%s\n' "$@" > "$ARGUMENTS_FILE"
        cat "$FIXTURE_FILE"
        exit "${XCRUN_STATUS:-0}"
      SH
      fixture = bin / "tests.json"
      fixture.write(JSON.generate("testNodes" => [{ "nodeType" => "Test Case", "name" => "café 🚀", "result" => "Passed" }]))
      environment = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "ARGUMENTS_FILE" => (bin / "arguments").to_s,
                      "FIXTURE_FILE" => fixture.to_s }
      command = [ROOT / "scripts/xcresult-to-junit.rb", "bundle with spaces.xcresult"]
      stdout, stderr, status = capture_c_locale(*command, environment: environment)
      assert status.success?, stderr
      assert_equal "testsuites", REXML::Document.new(stdout).root.name
      assert_equal "café 🚀", REXML::Document.new(stdout).root.elements["testsuite/testcase"].attributes["name"]
      assert_equal ["xcresulttool", "get", "test-results", "tests", "--path", "bundle with spaces.xcresult"], (bin / "arguments").read.lines.map(&:chomp)
      _stdout, _stderr, status = capture_c_locale(*command, environment: environment.merge("XCRUN_STATUS" => "9"))
      refute status.success?
    end
  end

  def test_unnamed_bundles_use_unknown_suite_name
    [nil, "", "\e\uFFFE"].each do |name|
      data = { "testNodes" => [{ "nodeType" => "Test Bundle", "name" => name, "children" => [
        { "nodeType" => "Test Case", "name" => "example", "result" => "Passed" }] }] }
      suite = REXML::Document.new(XCResultJUnit.convert(data)).root.elements["testsuite"]
      assert_equal "Unknown", suite.attributes["name"]
      assert_equal "Unknown", suite.elements["testcase"].attributes["classname"]
    end
  end

  def test_nested_suite_names_preserve_missing_null_and_empty_distinctions
    names = [{}, { "name" => nil }, { "name" => "" }, { "name" => "Suite" }]
    expected = [[".", ".None", ".", ".Suite"],
                ["Unknown", "Unknown", "Unknown", "Suite"],
                [".", ".None", ".", ".Suite"],
                ["Suite.", "Suite.None", "Suite.", "Suite.Suite"]]
    names.each_with_index do |parent, parent_index|
      names.each_with_index do |child, child_index|
        data = { "testNodes" => [{ "nodeType" => "Test Bundle", **parent, "children" => [
          { "nodeType" => "Test Suite", **child, "children" => [
            { "nodeType" => "Test Case", "name" => "example", "result" => "Passed" }] }] }] }
        suite = REXML::Document.new(XCResultJUnit.convert(data)).root.elements["testsuite"]
        label = expected[parent_index][child_index]
        assert_equal label, suite.attributes["name"], "parent=#{parent.inspect}, child=#{child.inspect}"
        assert_equal label, suite.elements["testcase"].attributes["classname"]
      end
    end
  end

  def test_null_names_and_xml_invalid_characters_do_not_discard_the_report
    data = { "testNodes" => [{ "nodeType" => "Test Bundle", "name" => "Bundle\e\uFFFE", "children" => [
      { "nodeType" => "Test Suite", "name" => nil, "children" => [
        { "nodeType" => "Test Case", "name" => nil, "result" => "Failed", "children" => [
          { "nodeType" => "Failure Message", "name" => nil, "children" => nil },
          { "nodeType" => "Failure Message", "name" => "café\0\e\v\f\uFFFE 🚀\nnext line" }] },
        { "nodeType" => "Test Case", "name" => "clean\e name", "result" => "Passed", "children" => nil }] }] }] }
    xml = XCResultJUnit.convert(data)
    refute XMLText::INVALID_CHARACTERS.match?(xml)
    suite = REXML::Document.new(xml).root.elements["testsuite"]
    assert_equal "2", suite.attributes["tests"]
    assert_equal "1", suite.attributes["failures"]
    assert_equal "Bundle.None", suite.attributes["name"]
    assert_equal "", suite.elements["testcase"].attributes["name"]
    assert_equal "clean name", suite.elements["testcase[2]"].attributes["name"]
    assert_equal "café 🚀\nnext line", suite.elements["testcase/failure"].text
    assert_empty REXML::Document.new(XCResultJUnit.convert({ "testNodes" => nil })).root.elements.to_a
  end
end
