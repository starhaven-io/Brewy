# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class CIConclusionTests < Minitest::Test
  include HelperTestSupport

  def setup
    @script = workflow_run_block((ROOT / ".github/workflows/ci.yml").read, "Result")
    @environment = {
      "GITHUB_EVENT_NAME" => "pull_request", "GENERATOR_RESULT" => "success", "COMMITS_RESULT" => "success",
      "CHECK_RESULT" => "success", "CODEQL_RESULT" => "success", "ZIZMOR_RESULT" => "success", "PINPRICK_RESULT" => "success",
      "CODECOV_RESULT" => "success", "MATRIX" => '[{"check":"test"}]', "RUN_CODEQL" => "true", "RUN_ZIZMOR" => "true",
      "RUN_CODECOV" => "true", "CODECOV_ELIGIBLE" => "true", "EVENT_NAME" => "pull_request"
    }
  end

  def conclude(overrides = {})
    capture(@environment.merge(overrides), "/bin/bash", "-euo", "pipefail", "-c", @script).last.success?
  end

  def test_required_audit_results_fail_closed
    assert conclude
    ["failure", "cancelled", "skipped", ""].each { |result| refute conclude("PINPRICK_RESULT" => result) }
  end

  def test_conclusion_waits_for_and_reads_every_dependency
    conclusion = YAML.load_file(ROOT / ".github/workflows/ci.yml").fetch("jobs").fetch("conclusion")
    expected = {
      "GENERATOR_RESULT" => "generate-matrix", "COMMITS_RESULT" => "commits", "CHECK_RESULT" => "check",
      "CODEQL_RESULT" => "codeql", "ZIZMOR_RESULT" => "zizmor", "PINPRICK_RESULT" => "pinprick", "CODECOV_RESULT" => "codecov"
    }
    assert_equal expected.values.sort, conclusion.fetch("needs").sort
    assert_equal "always()", conclusion.fetch("if")
    environment = conclusion.fetch("steps").find { |step| step["name"] == "Result" }.fetch("env")
    expected.each { |name, job| assert_equal "${{ needs.#{job}.result }}", environment.fetch(name), name }
    expected.each_key do |name|
      %w[failure cancelled skipped].each { |result| refute conclude(name => result), "#{name}=#{result}" }
    end
  end

  def test_only_unselected_workflow_audits_may_skip
    assert conclude("RUN_ZIZMOR" => "false", "ZIZMOR_RESULT" => "skipped", "PINPRICK_RESULT" => "skipped")
    refute conclude("RUN_ZIZMOR" => "false", "ZIZMOR_RESULT" => "skipped", "PINPRICK_RESULT" => "failure")
    refute conclude("RUN_ZIZMOR" => "", "ZIZMOR_RESULT" => "skipped", "PINPRICK_RESULT" => "skipped")
  end

  def test_every_routing_decision_fails_closed
    refute conclude("EVENT_NAME" => "unknown", "COMMITS_RESULT" => "skipped")
    refute conclude("MATRIX" => "", "CHECK_RESULT" => "skipped")
    refute conclude("RUN_CODEQL" => "", "CODEQL_RESULT" => "skipped")
    refute conclude("RUN_CODECOV" => "", "CODECOV_RESULT" => "skipped")
    refute conclude("CODECOV_ELIGIBLE" => "", "CODECOV_RESULT" => "skipped")
  end

  def test_ui_test_count_guard_handles_utf8_without_a_locale_and_still_rejects_zero
    script = workflow_run_block((ROOT / ".github/workflows/ci.yml").read, "Verify UI test runner signature")
    stub = <<~'SH'
      find() { printf '%s\n' /fixture; }
      codesign() { :; }
      xcrun() { printf '%s' "${SUMMARY}"; }
    SH
    [1, 0].each do |count|
      environment = { "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil, "RESULT_BUNDLE" => "fixture",
                      "SUMMARY" => JSON.generate("totalTestCount" => count, "name" => "café 🚀") }
      stdout, stderr, status = capture(environment, "/bin/bash", "-euo", "pipefail", "-c", stub + script)
      assert_equal count.positive?, status.success?, stdout + stderr
    end
  end
end
