# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class WorkflowContractTests < Minitest::Test
  include HelperTestSupport

  def test_release_jobs_use_ruby_without_installing_dependencies
    workflow = YAML.load_file(RELEASE_WORKFLOW)
    %w[build release publish bump-cask].each do |name|
      steps = workflow.fetch("jobs").fetch(name).fetch("steps")
      setup = steps.find { |step| step["name"] == "Set up Ruby" }
      assert_equal "none", setup.fetch("with").fetch("bundler"), name
      assert_equal false, setup.fetch("with").fetch("bundler-cache"), name
      commands = steps.filter_map { |step| step["run"] }.join("\n")
      refute_match(/\bbundle\s|\bgem\s+install\b/, commands, name)
      assert_match(/\bruby scripts\/release-delivery\.rb\b/, commands, name)
    end
  end

  def test_plain_ruby_loads_release_helpers_with_bundled_rexml
    Dir.mktmpdir("brewy-release-runtime-") do |directory|
      probe = Pathname(directory) / "runtime.rb"
      probe.write(<<~'RUBY')
        abort "Bundler is active" if $LOADED_FEATURES.any? { |path| path.end_with?("/bundler/setup.rb") }
        require ARGV.fetch(0)
        require ARGV.fetch(1)
        spec = Gem.loaded_specs.fetch("rexml")
        abort "REXML came from an external gem path" unless spec.full_gem_path.start_with?(Gem.default_dir + "/")
        puts "Release helpers load without Bundler"
      RUBY
      stdout, stderr, status = capture_release_ruby(probe, (ROOT / "scripts/release-delivery.rb").to_s,
                                                    (ROOT / ".github/format-release-notes.rb").to_s)
      assert status.success?, stderr
      assert_equal "Release helpers load without Bundler\n", stdout
    end
  end

  def test_interpreted_codeql_covers_ruby_tooling_after_main_pushes
    workflow = YAML.load_file(ROOT / ".github/workflows/codeql-interpreted.yml")
    push = workflow.fetch("on") { workflow.fetch(true) }.fetch("push")
    assert_equal ["main"], push.fetch("branches")
    assert_equal %w[scripts/** .github/format-release-notes.rb Gemfile Gemfile.lock .ruby-version .github/workflows/codeql-interpreted.yml].sort,
                 push.fetch("paths").sort
    job = workflow.fetch("jobs").fetch("analyze")
    swift = YAML.load_file(ROOT / ".github/workflows/codeql.yml").fetch("jobs").fetch("analyze")
    assert_equal swift.fetch("uses"), job.fetch("uses")
    assert_equal ["ruby"], JSON.parse(job.fetch("with").fetch("languages"))
    refute job.fetch("with").key?("build-mode")
    refute job.fetch("with").key?("build-profile")
    assert_equal "ubuntu-slim", job.fetch("with").fetch("runner")
    assert_equal({ "contents" => "read", "security-events" => "write" }, job.fetch("permissions"))
  end
end
