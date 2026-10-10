# frozen_string_literal: true

Encoding.default_external = Encoding::UTF_8

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require "timeout"

module HelperTestSupport
  ROOT = Pathname(__dir__).parent.parent
  RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"

  def workflow_run_block(workflow, step_name, strip_comments: true)
    marker = "      - name: #{step_name}\n"
    offset = workflow.index(marker)
    raise "missing workflow step: #{step_name}" unless offset

    step = workflow[(offset + marker.length)..].split(/^      - /, 2).first
    run = step.split("        run: |\n", 2).fetch(1)
    run.lines.take_while { |line| line.strip.empty? || line.start_with?("          ") }
       .reject { |line| strip_comments && line.lstrip.start_with?("#") }
       .map { |line| line.delete_prefix("          ") }.join
  end

  def capture(*arguments, **options)
    Timeout.timeout(20) { Open3.capture3(*arguments, **options) }
  end

  def capture_c_locale(script, *arguments, environment: {})
    loader = <<~'RUBY'
      abort "Expected US-ASCII external encoding" unless Encoding.default_external == Encoding::US_ASCII
      abort "Test helper leaked into child" if $LOADED_FEATURES.any? { |path| path.end_with?("/test_helper.rb") }
      $0 = ARGV.shift
      load $0
    RUBY
    capture({ "LANG" => "C", "LC_ALL" => "C", "LC_CTYPE" => "C" }.merge(environment),
            RbConfig.ruby, "-EUS-ASCII", "-e", loader, "--", script.to_s, *arguments)
  end

  def capture_release_ruby(script, *arguments, environment: {})
    clean = ENV.keys.select { |key| key.start_with?("BUNDLE_", "BUNDLER_") }.to_h { |key| [key, nil] }
    clean.merge!("RUBYOPT" => nil, "RUBYLIB" => nil, "GEM_HOME" => Gem.default_dir, "GEM_PATH" => Gem.default_dir)
    capture(clean.merge(environment), RbConfig.ruby, script.to_s, *arguments)
  end

  def write_executable(path, content)
    File.write(path, content)
    File.chmod(0o755, path)
  end
end
