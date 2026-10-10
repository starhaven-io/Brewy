# frozen_string_literal: true

require_relative "test_helper"

class CaskMergeProtocolTests < Minitest::Test
  include HelperTestSupport

  def test_merge_is_bounded_synchronous_and_exact_head_bound
    workflow = RELEASE_WORKFLOW.read
    resolve = workflow_run_block(workflow, "Resolve Homebrew cask bump")
    wait = workflow_run_block(workflow, "Wait for checks on the validated head")
    revalidate = workflow_run_block(workflow, "Revalidate and merge the exact head")
    merge_job = workflow.split("\n  merge-cask-bump:\n", 2).last
    ['if [[ "${MATCH_COUNT}" != 1 ]]', '.user.login == $bot', '.changed_files == 1',
     'echo "base_sha=', 'echo "head_sha='].each { |text| assert_includes resolve, text }
    refute_includes resolve, "gh pr merge"
    ["CHECK_TIMEOUT_SECONDS=1500", "8) CHECK_SUMMARY=pending", "mergeStateStatus", "CHECK_STATUS == 0",
     '[[ "${MERGE_STATE}" == "CLEAN" || "${MERGE_STATE}" == "UNSTABLE" ]]'].each { |text| assert_includes wait, text }
    %w[--watch --fail-fast].each { |text| refute_includes wait, text }
    assert_operator merge_job.index("Wait for checks on the validated head"), :<, merge_job.index("Mint bot token for tap")
    ['.base.sha == $base_sha', '.head.sha == $head', '.[0].filename == $cask',
     '--match-head-commit "${HEAD_SHA}"'].each { |text| assert_includes revalidate, text }
    refute_includes merge_job, "--auto"
  end

  def test_partial_required_check_registration_stays_blocked
    wait = workflow_run_block(RELEASE_WORKFLOW.read, "Wait for checks on the validated head")
           .sub("CHECK_INTERVAL_SECONDS=10", "CHECK_INTERVAL_SECONDS=0")
    stub = <<~'SH'
      gh() {
        if [[ "$1" == api ]]; then printf '%s\n' validated-head; return; fi
        if [[ "$1" == pr && "$2" == checks && "$*" == *--json* ]]; then
          printf '1\n'; return
        fi
        if [[ "$1" == pr && "$2" == checks ]]; then
          index=$(< "${GH_FIXTURE_COUNTER}")
          if [[ "${index}" == 1 ]]; then return 8; fi
          return
        fi
        if [[ "$1" == pr && "$2" == view ]]; then
          index=$(< "${GH_FIXTURE_COUNTER}")
          printf '%s\n' "$((index + 1))" > "${GH_FIXTURE_COUNTER}"
          cat "${GH_FIXTURE_DIR}/${index}.json"
          return
        fi
        return 1
      }
    SH
    Dir.mktmpdir("brewy-checks-test-") do |directory|
      path = Pathname(directory)
      counter = path / "counter"
      counter.write("0\n")
      %w[BLOCKED BLOCKED CLEAN].each_with_index do |state, index|
        (path / "#{index}.json").write(JSON.generate("headRefOid" => "validated-head", "mergeStateStatus" => state))
      end
      stdout, stderr, status = capture({ "GH_FIXTURE_COUNTER" => counter.to_s, "GH_FIXTURE_DIR" => directory,
                                        "PR_NUMBER" => "159", "HEAD_SHA" => "validated-head" },
                                      "/bin/bash", "-euo", "pipefail", "-c", stub + wait)
      assert status.success?, stdout + stderr
      assert_equal "3", counter.read.strip
      assert_equal 2, stdout.scan("merge state: BLOCKED").length
      assert_includes stdout, "merge state: CLEAN"
    end
  end
end

class CaskDCOTests < Minitest::Test
  include HelperTestSupport

  def setup
    @temporary = Dir.mktmpdir("brewy-dco-test-")
    @root = Pathname(@temporary).realpath
    @tap, @runner, @bin = ["tap checkout", "runner temp", "bin"].map { |name| @root / name }
    [@tap, @runner, @bin].each(&:mkdir)
    @environment = ENV.to_h.reject { |key, _| key.start_with?("GIT_") }.merge(
      "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL, "GIT_TERMINAL_PROMPT" => "0",
      "GIT_AUTHOR_NAME" => "Fixture Author", "GIT_AUTHOR_EMAIL" => "author@example.test",
      "PATH" => "#{@bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}", "RUNNER_TEMP" => @runner.to_s,
      "TAP_ROOT" => @tap.to_s, "APP_SLUG" => "fixture-bot", "VERSION" => "1.2.3"
    )
    git("init", "-q")
    git("config", "user.name", "Fixture Committer")
    git("config", "user.email", "committer@example.test")
    git("config", "core.hooksPath", ".githooks")
    @hooks = @tap / ".githooks"
    @hooks.mkdir
    write_executable(@hooks / "commit-msg", (ROOT / ".githooks/commit-msg").read)
    write_executable(@hooks / "pre-push", "#!/bin/sh\nexit 1\n")
    write_executable(@bin / "gh", "#!/bin/sh\nif [ \"$1\" = api ]; then printf \"42\\n\"; fi\n")
    write_executable(@bin / "brew", <<~'SH')
      #!/bin/sh
      set -eu
      case "$1" in
        --repo) printf '%s\n' "$TAP_ROOT" ;;
        tap|trust) ;;
        bump-cask-pr)
          if [ "${REPLACE_HOOK:-0}" = 1 ]; then
            rm "$TAP_ROOT/.githooks/prepare-commit-msg"
            ln -s "$TAP_ROOT/keep-this-link" "$TAP_ROOT/.githooks/prepare-commit-msg"
            exit 9
          fi
          [ "${FAIL_BREW:-0}" = 0 ] || exit 9
          printf 'update\n' >> "$TAP_ROOT/cask.rb"
          git -C "$TAP_ROOT" add cask.rb
          message='brewy 1.2.3'
          if [ "${EXISTING_SIGNOFF:-0}" = 1 ]; then
            message="$(printf '%s\n\nSigned-off-by: Fixture Author <author@example.test>\n' "$message")"
          fi
          git -C "$TAP_ROOT" -c commit.gpgSign=false commit --no-edit --verbose --message="$message" -- cask.rb
          ;;
        *) exit 8 ;;
      esac
    SH
    @script = workflow_run_block(RELEASE_WORKFLOW.read, "Bump Homebrew cask", strip_comments: false)
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def git(*arguments)
    stdout, stderr, status = capture(@environment, "git", "-C", @tap.to_s, *arguments, unsetenv_others: true)
    raise stderr unless status.success?

    stdout.strip
  end

  def run_bump
    capture(@environment, "/bin/bash", "-eu", "-o", "pipefail", "-c", @script, chdir: @root, unsetenv_others: true)
  end

  def assert_cleaned
    refute (@hooks / "prepare-commit-msg").symlink?
    assert_empty @runner.children
    assert_equal ".githooks", git("config", "--local", "core.hooksPath")
  end

  def test_actual_author_is_signed_once_and_existing_hooks_are_preserved
    original = (@hooks / "commit-msg").binread
    %w[0 1].each do |duplicate|
      @environment["EXISTING_SIGNOFF"] = duplicate
      stdout, stderr, status = run_bump
      assert status.success?, stdout + stderr
      message = git("log", "-1", "--format=%B")
      author = git("log", "-1", "--format=%an <%ae>")
      assert_equal "brewy 1.2.3", message.lines.first.chomp
      assert_equal 1, message.scan("Signed-off-by:").length
      assert_includes message, "Signed-off-by: #{author}"
      refute_equal author, git("log", "-1", "--format=%cn <%ce>")
      assert_equal original, (@hooks / "commit-msg").binread
      assert_equal "#!/bin/sh\nexit 1\n", (@hooks / "pre-push").read
      assert_cleaned
    end
  end

  def test_existing_validator_still_blocks_commit
    write_executable(@hooks / "commit-msg", "#!/bin/sh\nexit 1\n")
    refute run_bump.last.success?
    assert_cleaned
  end

  def test_failure_cleans_hook_for_retry
    @environment["FAIL_BREW"] = "1"
    assert_equal 9, run_bump.last.exitstatus
    assert_cleaned
    @environment["FAIL_BREW"] = "0"
    assert run_bump.last.success?
    assert_cleaned
  end

  def test_existing_prepare_hook_is_preserved
    prepare = @hooks / "prepare-commit-msg"
    write_executable(prepare, "#!/bin/sh\nexit 0\n")
    before = prepare.binread
    stdout, _stderr, status = run_bump
    refute status.success?
    assert_includes stdout, "existing prepare-commit-msg"
    assert_equal before, prepare.binread
    assert_empty @runner.children
  end

  def test_external_hook_directory_is_not_modified
    external = @root / "outside hooks"
    external.mkdir
    link = @tap / "outside-link"
    File.symlink(external, link)
    [external, link].each do |location|
      git("config", "core.hooksPath", location.to_s)
      stdout, _stderr, status = run_bump
      refute status.success?
      assert_includes stdout, "outside the fresh checkout"
      assert_empty external.children
      assert_empty @runner.children
    end
  end

  def test_inherited_global_hook_directory_is_not_modified
    external = @root / "global hooks"
    external.mkdir
    global_config = @root / "gitconfig"
    @environment["GIT_CONFIG_GLOBAL"] = global_config.to_s
    git("config", "--global", "core.hooksPath", external.to_s)
    git("config", "--local", "--unset", "core.hooksPath")
    before = global_config.binread
    refute run_bump.last.success?
    assert_equal before, global_config.binread
    assert_empty external.children
    assert_empty @runner.children
  end

  def test_cleanup_preserves_a_substituted_link
    @environment["REPLACE_HOOK"] = "1"
    assert_equal 9, run_bump.last.exitstatus
    assert_equal (@tap / "keep-this-link").to_s, File.readlink(@hooks / "prepare-commit-msg")
    assert_empty @runner.children
  end
end
