# frozen_string_literal: true

require_relative "test_helper"
require_relative "../ci-path-routing"

class CIPathRoutingTests < Minitest::Test
  include HelperTestSupport

  def test_path_cases
    CIPathRouting.validate
    router = CIPathRouting.new
    router.route("scripts/xcresult-to-junit.rb")
    assert router.routes["tests"]
    assert router.routes["release_helpers"]
  end

  def generate(paths:, trusted: true, diff_status: 0, event: "pull_request", base: "a" * 40)
    Dir.mktmpdir("brewy-router-test-") do |directory|
      path = Pathname(directory)
      (path / "changed").binwrite(paths.join("\0") + (paths.empty? ? "" : "\0"))
      FileUtils.cp(ROOT / "scripts/ci-path-routing.rb", path / "trusted.rb")
      stub = <<~'SH'
        git() {
          printf '%s\n' "$1" >> "${RUNNER_TEMP}/git-calls"
          if [[ "$1" == diff ]]; then
            cat "${RUNNER_TEMP}/changed"
            return "${DIFF_STATUS}"
          fi
          if [[ "$1" == show && "${TRUSTED}" == true ]]; then
            cat "${RUNNER_TEMP}/trusted.rb"
            return
          fi
          return 1
        }
      SH
      script = workflow_run_block((ROOT / ".github/workflows/ci.yml").read, "Generate CI matrix")
      stdout, stderr, status = capture({ "RUNNER_TEMP" => directory, "GITHUB_OUTPUT" => (path / "outputs").to_s,
                                        "EVENT_NAME" => event, "BASE_SHA" => base, "DIFF_STATUS" => diff_status.to_s,
                                        "TRUSTED" => trusted.to_s }, "/bin/bash", "-euo", "pipefail", "-c", stub + script)
      output = (path / "outputs").exist? ? (path / "outputs").read.lines.to_h { |line| line.chomp.split("=", 2) } : {}
      calls = (path / "git-calls").exist? ? (path / "git-calls").read.lines : []
      [status, output, stdout + stderr, calls]
    end
  end

  def test_raw_control_character_names_select_tests_and_audits
    status, outputs, logs = generate(paths: ["Brewy/newline\ninput.swift"])
    assert status.success?, logs
    checks = JSON.parse(outputs.fetch("matrix")).map { |entry| entry.fetch("check") }
    %w[lint test-tsan test-ui test-asan build-release].each { |check| assert_includes checks, check }
    assert_equal "true", outputs["run_codeql"]
    assert_equal "true", outputs["run_codecov"]
  end

  def test_missing_trusted_router_selects_all_checks
    status, outputs, logs = generate(paths: ["README.md"], trusted: false)
    assert status.success?, logs
    assert_equal 7, JSON.parse(outputs.fetch("matrix")).length
    %w[run_codeql run_zizmor run_codecov].each { |key| assert_equal "true", outputs[key] }
  end

  def test_router_and_dependency_changes_select_all_checks
    %w[scripts/ci-path-routing.rb Gemfile Gemfile.lock .ruby-version].each do |changed|
      status, outputs, logs = generate(paths: [changed])
      assert status.success?, logs
      assert_equal 7, JSON.parse(outputs.fetch("matrix")).length
    end
  end

  def test_failed_diff_does_not_produce_a_passing_empty_matrix
    status, outputs, = generate(paths: [], diff_status: 2)
    refute status.success?
    assert_empty outputs
  end

  def test_shared_xml_library_selects_tests_and_release_helpers
    status, outputs, logs = generate(paths: ["scripts/lib/xml-text.rb"])
    assert status.success?, logs
    assert_equal %w[lint test-tsan test-ui test-asan build-release release-helpers],
                 JSON.parse(outputs.fetch("matrix")).map { |entry| entry.fetch("check") }
    assert_equal "true", outputs.fetch("run_codecov")
  end

  def test_invalid_base_is_rejected_before_git_access
    ["", "HEAD", "-evil", "a" * 39, "a" * 41, "g" * 40, "#{'a' * 40}\n"].each do |base|
      status, outputs, logs, calls = generate(paths: [], base: base)
      refute status.success?
      assert_empty outputs
      assert_includes logs, "Pull request base SHA must be a full commit hash."
      assert_empty calls
    end
  end

  def test_lint_configuration_and_model_data_select_required_checks
    { ".swiftlint.yml" => %w[lint test-tsan test-ui test-asan build-release],
      "Brewy/Models/fixture.json" => %w[lint test-tsan test-ui test-asan build-release probe-build] }.each do |path, checks|
      status, outputs, logs = generate(paths: [path])
      assert status.success?, logs
      assert_equal checks, JSON.parse(outputs.fetch("matrix")).map { |entry| entry.fetch("check") }
      assert_equal path.start_with?("Brewy/").to_s, outputs.fetch("run_codeql")
      assert_equal "true", outputs.fetch("run_codecov")
    end
  end

  def test_docs_and_main_push_retain_expected_routes
    status, outputs, logs = generate(paths: ["README.md"])
    assert status.success?, logs
    assert_equal ["lint"], JSON.parse(outputs.fetch("matrix")).map { |entry| entry["check"] }
    assert_equal "false", outputs["run_codeql"]
    status, outputs, logs = generate(paths: [], event: "push", base: "")
    assert status.success?, logs
    assert_equal %w[lint probe-build test-tsan test-ui release-helpers], JSON.parse(outputs.fetch("matrix")).map { |entry| entry["check"] }
    assert_equal "false", outputs["run_codeql"]
    assert_equal "true", outputs["run_codecov"]
  end
end

class TrustedRoutingTests < Minitest::Test
  include HelperTestSupport

  def fixture_environment
    ENV.to_h.reject { |key, _| key.start_with?("GIT_") }
       .merge("GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL)
  end

  def fixture_git(directory, *arguments)
    stdout, stderr, status = capture(fixture_environment, "git", "-C", directory.to_s, *arguments, unsetenv_others: true)
    raise stderr unless status.success?

    stdout.strip
  end

  def fixture_commit(path, message)
    fixture_git(path, "add", ".")
    fixture_git(path, "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", message)
    fixture_git(path, "rev-parse", "HEAD")
  end

  def with_fixture(version: "4.0.6", router: true)
    Dir.mktmpdir("brewy-trusted-router-test-") do |directory|
      path = Pathname(directory)
      fixture_git(path, "init", "-q")
      fixture_git(path, "config", "user.name", "Fixture Author")
      fixture_git(path, "config", "user.email", "fixture@example.test")
      (path / "Brewy").mkdir
      (path / "Brewy/source.swift").write("let value = 1\n" * 20)
      (path / ".ruby-version").write(version + "\n") if version
      if router
        (path / "scripts").mkdir
        FileUtils.cp(ROOT / "scripts/ci-path-routing.rb", path / "scripts/ci-path-routing.rb")
      end
      base = fixture_commit(path, "Fixture base")
      yield path, base
    end
  end

  def select_runtime(path, base)
    output = path / "ruby-output"
    calls = Pathname("#{output}.git-calls")
    FileUtils.rm_f(calls)
    FileUtils.rm_f(output)
    script = workflow_run_block((ROOT / ".github/workflows/ci.yml").read, "Select trusted router Ruby")
    script = 'git() { printf "%s\n" "$1" >> "${GITHUB_OUTPUT}.git-calls"; command git "$@"; }' + "\n" + script
    stdout, stderr, status = capture(fixture_environment.merge("BASE_SHA" => base, "GITHUB_OUTPUT" => output.to_s),
                                    "/bin/bash", "-euo", "pipefail", "-c", script, chdir: path, unsetenv_others: true)
    [status, output.exist? ? output.read : "", stdout + stderr, calls.exist? ? calls.read.lines : []]
  end

  def test_router_interpreter_comes_from_base_not_head
    with_fixture do |path, base|
      (path / ".ruby-version").write("ruby-head\n")
      fixture_commit(path, "Fixture untrusted runtime change")
      status, output, logs = select_runtime(path, base)
      assert status.success?, logs
      assert_equal "version=4.0.6\n", output
    end
    require "yaml"
    steps = YAML.load_file(ROOT / ".github/workflows/ci.yml").fetch("jobs").fetch("generate-matrix").fetch("steps")
    setup = steps.find { |step| step["name"] == "Set up Ruby" }
    assert_equal "${{ steps.trusted-ruby.outputs.version }}", setup.fetch("with").fetch("ruby-version")
    assert_equal "none", setup.fetch("with").fetch("bundler")
    assert_equal "steps.trusted-ruby.outputs.version != ''", setup.fetch("if")
  end

  def test_missing_or_invalid_base_runtime_fails_closed
    [nil, "ruby-head", "4.0.7\nversion=ruby-head"].each do |version|
      with_fixture(version: version) do |path, base|
        status, output, = select_runtime(path, base)
        refute status.success?
        assert_empty output
      end
    end
  end

  def test_first_router_introduction_needs_no_base_ruby_install
    with_fixture(version: nil, router: false) do |path, base|
      status, output, logs = select_runtime(path, base)
      assert status.success?, logs
      assert_empty output
    end
  end

  def test_runtime_selection_rejects_invalid_base_before_git_access
    with_fixture do |path, _base|
      ["", "HEAD", "-evil", "a" * 39, "a" * 41, "g" * 40, "#{'a' * 40}\n"].each do |base|
        status, output, logs, calls = select_runtime(path, base)
        refute status.success?
        assert_empty output
        assert_includes logs, "Pull request base SHA must be a full commit hash."
        assert_empty calls
      end
    end
  end

  def test_workflow_fixtures_ignore_inherited_git_context
    original = ENV.to_h
    Dir.mktmpdir("brewy-outer-git-test-") do |directory|
      path = Pathname(directory)
      fixture_git(path, "init", "-q")
      index = path / "sentinel-index"
      index.binwrite("outer checkout index must stay untouched")
      ENV.update("GIT_DIR" => (path / ".git").to_s, "GIT_WORK_TREE" => path.to_s, "GIT_INDEX_FILE" => index.to_s)
      test_router_interpreter_comes_from_base_not_head
      test_renaming_swift_source_to_documentation_still_selects_tests
      assert_equal "outer checkout index must stay untouched", index.binread
      assert_empty fixture_git(path, "ls-files")
    end
  ensure
    ENV.replace(original)
  end

  def test_renaming_swift_source_to_documentation_still_selects_tests
    with_fixture do |path, base|
      (path / "docs").mkdir
      fixture_git(path, "mv", "Brewy/source.swift", "docs/notes.md")
      fixture_commit(path, "Fixture source rename")
      assert_equal "docs/notes.md", fixture_git(path, "diff", "--name-only", "#{base}...HEAD")
      (path / "runner").mkdir
      output = path / "matrix-output"
      script = workflow_run_block((ROOT / ".github/workflows/ci.yml").read, "Generate CI matrix")
      stdout, stderr, status = capture(fixture_environment.merge("BASE_SHA" => base, "EVENT_NAME" => "pull_request",
                                                               "RUNNER_TEMP" => (path / "runner").to_s, "GITHUB_OUTPUT" => output.to_s),
                                      "/bin/bash", "-euo", "pipefail", "-c", script, chdir: path, unsetenv_others: true)
      assert status.success?, stdout + stderr
      results = output.read.lines.to_h { |line| line.chomp.split("=", 2) }
      %w[test-tsan test-ui test-asan build-release].each do |check|
        assert_includes JSON.parse(results.fetch("matrix")).map { |entry| entry.fetch("check") }, check
      end
      assert_equal "true", results.fetch("run_codeql")
      assert_equal "true", results.fetch("run_codecov")
    end
  end
end
