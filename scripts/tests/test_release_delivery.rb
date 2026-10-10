# frozen_string_literal: true

require_relative "test_helper"
require_relative "../release-delivery"

class ReleaseDeliveryTests < Minitest::Test
  include HelperTestSupport

  def setup
    @temporary = Dir.mktmpdir("brewy-release-test-")
    @directory = Pathname(@temporary)
    @asset = "notarized and stapled archive"
    @metadata = {
      "repository" => "starhaven-io/Brewy", "commit" => "a" * 40,
      "tag" => "0.27.0", "build" => "36", "asset" => "Brewy-0.27.0.zip", "release_id" => 42,
      "sha256" => Digest::SHA256.hexdigest(@asset), "length" => @asset.bytesize
    }
    @feed = @directory / "appcast.xml"
    write_feed(@feed, "0.27.0", "36")
    @metadata["appcast_sha256"] = ReleaseDelivery.sha256(@feed)
    @hosted_asset = { "id" => 73, "name" => @metadata["asset"], "size" => @asset.bytesize,
                      "digest" => "sha256:#{@metadata['sha256']}" }
    save_manifest
    @original_environment = ENV.to_h
    ENV.update("GITHUB_REPOSITORY" => @metadata["repository"], "GITHUB_SHA" => @metadata["commit"],
               "TAG" => @metadata["tag"], "BUILD_NUMBER" => @metadata["build"],
               "GH_PUBLISH_TOKEN" => "fixture-publish-token", "GH_TOKEN" => "fixture-read-token", "RELEASE_ID" => "42")
    @published = false
    @tag_sha = @metadata["commit"]
    @commands = []
    @original_run = ReleaseDelivery.method(:run)
    fixture = method(:fake_run)
    ReleaseDelivery.define_singleton_method(:run) { |*args, **kwargs| fixture.call(*args, **kwargs) }
  end

  def teardown
    ReleaseDelivery.define_singleton_method(:run, @original_run)
    ENV.replace(@original_environment)
    FileUtils.remove_entry(@temporary)
  end

  def write_feed(path, tag, build)
    path.write(<<~XML)
      <rss xmlns:sparkle="#{ReleaseDelivery::SPARKLE}"><channel><item>
      <sparkle:shortVersionString>#{tag}</sparkle:shortVersionString>
      <sparkle:version>#{build}</sparkle:version>
      <enclosure url="https://github.com/starhaven-io/Brewy/releases/download/#{tag}/Brewy-#{tag}.zip"
      length="#{@asset.bytesize}" sparkle:edSignature="prepared-signature"/>
      </item></channel></rss>
    XML
  end

  def save_manifest
    (@directory / "delivery.json").write(JSON.generate(@metadata))
  end

  def fake_run(args, token: nil, output: nil)
    @commands << args
    case args[1..2]
    when ["api", "--include"]
      status = @bad_tag_status || (@published ? "200" : "404")
      return ["HTTP/2.0 #{status} Fixture\n\n{}", "", status == "200" ? 0 : 1]
    when ["api", "repos/starhaven-io/Brewy/releases/assets/73"]
      assert_equal ["--header", "Accept: application/octet-stream"], args[3..]
      assert_equal "fixture-publish-token", token unless @published
      output.write(@asset)
      @hosted_asset["id"] = 74 if @replace_asset_after_download
      return [nil, "", 0]
    when ["api", "repos/starhaven-io/Brewy/releases/42"]
      if args.include?("--method")
        assert_equal ["--method", "PATCH", "-F", "draft=false", "-f", "tag_name=0.27.0",
                      "-f", "target_commitish=#{'a' * 40}"], args[3..]
        assert_equal "fixture-publish-token", token
        assert @commands.any? { |command| command[1..2] == ["attestation", "verify"] }
        @published = true
        return ["{}", "", @lose_publish_response ? 1 : 0]
      end
    end
    if args[1] == "api"
      result = if args[2].include?("/commits/")
        { "sha" => @tag_sha }
      else
        assert_equal "repos/starhaven-io/Brewy/releases/42", args[2]
        assert_equal "fixture-publish-token", token unless @published
        { "id" => 42, "tag_name" => "0.27.0", "target_commitish" => "a" * 40,
          "draft" => !@published, "prerelease" => false, "assets" => [@hosted_asset] }
      end
      return [JSON.generate(result), "", 0]
    end
    assert_equal ["attestation", "verify"], args[1..2]
    assert_nil token
    assert_equal "fixture-read-token", ENV.fetch("GH_TOKEN")
    assert_includes args, "--source-digest"
    assert_includes args, "a" * 40
    assert_includes args, "starhaven-io/Brewy/.github/workflows/release.yml"
    assert_includes args, "--deny-self-hosted-runners"
    ["", "", @provenance_fails ? 1 : 0]
  end

  def test_publish_then_retry_uses_existing_asset
    ReleaseDelivery.verify(@directory, publish: true)
    ReleaseDelivery.verify(@directory, publish: true)
    ReleaseDelivery.verify(@directory)
    assert_equal 1, @commands.count { |command| command.include?("PATCH") }
    assert_equal 3, @commands.count { |command| command[1..2] == ["attestation", "verify"] }
  end

  def test_lost_publication_response_recovers_without_republishing
    @lose_publish_response = true
    assert_raises(ReleaseDelivery::CommandError) { ReleaseDelivery.verify(@directory, publish: true) }
    ReleaseDelivery.verify(@directory, publish: true)
    assert_equal 1, @commands.count { |command| command.include?("PATCH") }
  end

  def test_asset_replaced_during_verification_prevents_publication
    @replace_asset_after_download = true
    error = assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
    assert_match(/asset identity changed/, error.message)
    refute @published
  end

  def test_invalid_asset_id_prevents_download
    @hosted_asset["id"] = "73"
    error = assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
    assert_match(/Invalid release asset ID/, error.message)
    refute @commands.any? { |command| command[2].include?("/releases/assets/") }
  end

  def test_provenance_failure_prevents_publication
    @provenance_fails = true
    assert_raises(ReleaseDelivery::CommandError) { ReleaseDelivery.verify(@directory, publish: true) }
    refute @published
  end

  def test_changed_archive_prevents_publication
    @asset = "X" * @asset.bytesize
    error = assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
    assert_match(/Release bytes differ/, error.message)
    refute @published
  end

  def test_cask_verification_requires_published_release
    # The read token is sufficient to inspect a draft in this fixture.
    @published = false
    fixture = method(:fake_run)
    ReleaseDelivery.define_singleton_method(:run) { |*args, **kwargs| fixture.call(*args, **kwargs.merge(token: "fixture-publish-token")) }
    error = assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory) }
    assert_match(/not published/, error.message)
    refute @published
  end

  def test_tag_lookup_errors_do_not_mean_absence
    %w[403 429 500].each do |status|
      @bad_tag_status = status
      error = assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
      assert_match(/Could not read release tag/, error.message)
    end
    refute @published
  end

  def test_changed_tag_blocks_recovery
    @published = true
    @tag_sha = "b" * 40
    error = assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
    assert_match(/tag binding changed/, error.message)
    refute @commands.any? { |command| command.include?("PATCH") }
  end

  def test_existing_tag_blocks_initial_publication
    @bad_tag_status = "200"
    error = assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
    assert_match(/tag binding changed/, error.message)
    refute @published
  end

  def test_tag_is_rechecked_after_publication
    @tag_sha = "b" * 40
    error = assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
    assert_match(/tag binding changed/, error.message)
    assert @published
  end

  def test_replaced_hosted_asset_prevents_recovery
    @published = true
    @hosted_asset["digest"] = "sha256:#{'b' * 64}"
    error = assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
    assert_match(/Release asset mismatch/, error.message)
    refute @commands.any? { |command| command.include?("PATCH") }
  end

  def test_mismatched_metadata_and_appcast_fail_before_network
    %w[commit tag build sha256 appcast_sha256 release_id length].each do |key|
      original = @metadata[key]
      @metadata[key] = "invalid"
      save_manifest
      assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
      assert_empty @commands
      @metadata[key] = original
    end
  end

  def test_retry_cannot_replace_newer_or_different_same_build_feed
    current = @directory / "current.xml"
    [["0.28.0", "37"], ["0.27.0", "36"], ["0.26.0", "36"]].each do |tag, build|
      write_feed(current, tag, build)
      current.write(current.read + "\n")
      assert_raises(ArgumentError) { ReleaseDelivery.check_feed(@feed, current) }
    end
    write_feed(current, "0.26.0", "35")
    ReleaseDelivery.check_feed(@feed, current)
    current.binwrite(@feed.binread)
    ReleaseDelivery.check_feed(@feed, current)
  end

  def test_both_release_version_and_build_must_increase
    current = @directory / "current.xml"
    write_feed(current, "0.26.0", "35")
    [["0.26.0", "36"], ["0.27.0", "35"], ["0.27.0", "0"], ["0.27.0", "36.1"]].each do |tag, build|
      assert_raises(ArgumentError) { ReleaseDelivery.check_version(tag, build, current) }
    end
    ReleaseDelivery.check_version("0.27.0", "36", current)
  end

  def test_namespace_identity_is_required_and_prefix_may_change
    @feed.write(@feed.read.gsub("sparkle:", "updates:").gsub("xmlns:sparkle", "xmlns:updates"))
    @metadata["appcast_sha256"] = ReleaseDelivery.sha256(@feed)
    ReleaseDelivery.validate_manifest(@directory, @metadata)
    @feed.write(@feed.read.gsub(ReleaseDelivery::SPARKLE, "https://example.test/wrong-namespace"))
    @metadata["appcast_sha256"] = ReleaseDelivery.sha256(@feed)
    assert_raises(ArgumentError) { ReleaseDelivery.validate_manifest(@directory, @metadata) }
  end

  def test_channel_and_item_must_be_in_the_empty_namespace
    original = @feed.read
    [original.sub("<rss ", '<rss xmlns="https://example.test/foreign" '),
     original.sub("<channel>", '<channel xmlns="https://example.test/foreign">'),
     original.sub("<item>", '<item xmlns="https://example.test/foreign">')].each do |xml|
      @feed.write(xml)
      @metadata["appcast_sha256"] = ReleaseDelivery.sha256(@feed)
      save_manifest
      error = assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
      assert_match(/Expected one release in the appcast/, error.message)
      assert_empty @commands
    end
  end

  def test_enclosure_must_be_in_the_empty_namespace
    original = @feed.read
    [original.sub("<enclosure ", '<enclosure xmlns="https://example.test/foreign" '),
     original.sub("<enclosure ", '<foreign:enclosure xmlns:foreign="https://example.test/foreign" ')].each do |xml|
      @feed.write(xml)
      @metadata["appcast_sha256"] = ReleaseDelivery.sha256(@feed)
      save_manifest
      error = assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
      assert_match(/Missing appcast enclosure/, error.message)
      assert_empty @commands
    end
  end

  def test_enclosure_attributes_must_be_in_the_empty_namespace
    original = @feed.read
    %w[url length].each do |attribute|
      xml = original.sub("<enclosure ", '<enclosure xmlns:foreign="https://example.test/foreign" ')
                    .sub("#{attribute}=", "foreign:#{attribute}=")
      @feed.write(xml)
      @metadata["appcast_sha256"] = ReleaseDelivery.sha256(@feed)
      save_manifest
      assert_raises(ArgumentError) { ReleaseDelivery.verify(@directory, publish: true) }
      assert_empty @commands
    end
  end

  def test_namespaced_root_may_reset_children_to_the_empty_namespace
    xml = @feed.read.sub("<rss ", '<rss xmlns="https://example.test/foreign" ')
               .sub("<channel>", '<channel xmlns="">')
    @feed.write(xml)
    @metadata["appcast_sha256"] = ReleaseDelivery.sha256(@feed)
    ReleaseDelivery.validate_manifest(@directory, @metadata)
    assert_equal ["0.27.0", "36"], ReleaseDelivery.feed(@feed).first(2)
  end

  def test_document_types_are_rejected
    @feed.write('<!DOCTYPE rss [<!ENTITY tag "0.27.0">]>' + @feed.read)
    assert_raises(ArgumentError) { ReleaseDelivery.feed(@feed) }
  end

  def test_prepare_and_verification_reject_invalid_xml_characters
    original = @feed.binread
    invalid = ["\e", "\v", "\f", "\uFFFE", "\uFFFF", "\xFF".b]
    payloads = invalid.flat_map { |text| [text.b, "<![CDATA[#{text}]]>".b] } + ["&#x1b;".b, "&#xFFFE;".b]
    payloads.each do |text|
      assert_appcast_rejected(original.sub("</item>".b, "<description>#{text}</description></item>".b))
    end
  end

  def test_raw_xml_source_rejects_comment_controls
    original = @feed.read(encoding: Encoding::UTF_8)
    ["\e", "\v", "\f", "\uFFFE"].each do |character|
      assert_appcast_rejected(original.sub("<channel>", "<channel><!-- hidden #{character} -->"))
    end
  end

  def test_raw_xml_source_rejects_non_utf8_encodings
    original = @feed.read(encoding: Encoding::UTF_8)
    unicode = original.sub("</item>", "<description>café</description></item>")
    %w[UTF-16 ISO-8859-1].each do |encoding|
      declared = %(<?xml version="1.0" encoding="#{encoding}"?>\n) + unicode
      assert_appcast_rejected(declared.encode(encoding))
    end
  end

  def assert_appcast_rejected(source)
    @feed.binwrite(source)
    @metadata["appcast_sha256"] = ReleaseDelivery.sha256(@feed)
    save_manifest
    assert_raises(ArgumentError, REXML::ParseException) { ReleaseDelivery.verify(@directory, publish: true) }
    assert_empty @commands
    assert_raises(ArgumentError, REXML::ParseException) { ReleaseDelivery.check_feed(@feed, @feed) }
    (@directory / "delivery.json").delete
    _stdout, _stderr, status = capture_release_ruby(ROOT / "scripts/release-delivery.rb", "prepare", @directory.to_s,
                                                   environment: { "ARTIFACT_SHA256" => @metadata["sha256"],
                                                                  "SPARKLE_LENGTH" => @asset.bytesize.to_s })
    refute status.success?
    refute (@directory / "delivery.json").exist?
  end

  def test_release_json_is_utf8_under_c_locale
    @metadata["notes"] = "café 🚀"
    save_manifest
    fixture = @directory / "gh-response.json"
    fixture.write(JSON.generate("sha" => @metadata["commit"], "notes" => @metadata["notes"]), encoding: Encoding::UTF_8)
    write_executable(@directory / "gh", <<~'SH')
      #!/bin/sh
      if [ "$2" = --include ]; then
        printf 'HTTP/2.0 200 OK\n\n{}'
      else
        cat "$GH_RESPONSE"
      fi
    SH
    probe = @directory / "locale-probe.rb"
    probe.write(<<~'RUBY')
      require ARGV.shift
      directory, commit = ARGV
      abort "Wrong tag commit" unless ReleaseDelivery.tag_commit("fixture/repo", "1.2.3") == commit
      ReleaseDelivery.define_singleton_method(:release_state) do |metadata, **|
        abort "Manifest lost Unicode" unless metadata.fetch("notes") == "café 🚀"
        throw :verified_manifest
      end
      catch(:verified_manifest) do
        ReleaseDelivery.verify(directory)
        abort "Manifest was not checked"
      end
      puts "UTF-8 release JSON verified"
    RUBY
    stdout, stderr, status = capture_c_locale(probe, (ROOT / "scripts/release-delivery.rb").to_s, @directory.to_s,
                                             @metadata["commit"], environment: { "PATH" => "#{@directory}:#{ENV.fetch('PATH')}",
                                                                                "GH_RESPONSE" => fixture.to_s })
    assert status.success?, stderr
    assert_equal "UTF-8 release JSON verified\n", stdout
  end

  def test_run_maps_publication_token_in_both_subprocess_modes
    command = [RbConfig.ruby, "-e", 'STDOUT.write(ENV.fetch("GH_TOKEN"))']
    [nil, "fixture-override-token"].each do |token|
      stdout, _stderr, status = @original_run.call(command, token: token)
      assert_equal 0, status
      assert_equal token || "fixture-read-token", stdout
      output_path = @directory / "token-result"
      output_path.open("wb") do |output|
        _stdout, _stderr, status = @original_run.call(command, token: token, output: output)
        assert_equal 0, status
      end
      assert_equal token || "fixture-read-token", output_path.read
      assert_equal "fixture-read-token", ENV.fetch("GH_TOKEN")
    end
  end

  def test_prepare_produces_verifiable_metadata
    stdout, stderr, status = capture_release_ruby(ROOT / "scripts/release-delivery.rb", "prepare", @directory.to_s,
                                                  environment: { "ARTIFACT_SHA256" => @metadata["sha256"],
                                                                 "SPARKLE_LENGTH" => @asset.bytesize.to_s })
    assert status.success?, stdout + stderr
    assert_equal @metadata, JSON.parse((@directory / "delivery.json").read)
  end

  def test_binary_download_stream_preserves_bytes_and_reports_failure
    file = @directory / "download"
    bytes = "archive\x00\xff\r\n".b
    warning = @directory / "startup-warning.rb"
    warning.write('warn "fixture startup warning"')
    ENV["RUBYOPT"] = [ENV["RUBYOPT"], "-r#{warning}"].compact.join(" ")
    file.open("wb") do |output|
      stdout, stderr, status = @original_run.call([RbConfig.ruby, "-e", 'STDOUT.binmode; STDOUT.write(ARGV[0].unpack1("m0")); warn "fixture error"; exit 3', [bytes].pack("m0")], output: output)
      assert_nil stdout
      assert_includes stderr, "fixture error\n"
      assert_includes stderr, "fixture startup warning\n"
      assert_equal 3, status
    end
    assert_equal bytes, file.binread
  end

  def test_built_app_must_match_both_requested_versions
    block = workflow_run_block(RELEASE_WORKFLOW.read, "Verify stapled app").gsub("/usr/libexec/PlistBuddy", "plist_buddy")
    stub = <<~'SH'
      ditto() { :; }
      codesign() { :; }
      xcrun() { :; }
      spctl() { :; }
      plist_buddy() {
        case "$2" in
          'Print :CFBundleShortVersionString') printf '%s' "${BUILT_VERSION}" ;;
          'Print :CFBundleVersion') printf '%s' "${BUILT_BUILD}" ;;
          *) return 1 ;;
        esac
      }
    SH
    [["0.27.0", "36", 0], ["0.27.0", "35", 1], ["0.26.0", "36", 1]].each do |tag, build, expected|
      stdout, stderr, status = capture({ "RUNNER_TEMP" => @directory.to_s, "ARTIFACT_NAME" => "test.zip", "BUILT_VERSION" => tag,
                                        "BUILT_BUILD" => build }, "/bin/bash", "-euo", "pipefail", "-c", stub + block)
      assert_equal expected, status.exitstatus, stdout + stderr
    end
  end

  def test_release_notes_update_keeps_the_draft_tag
    block = workflow_run_block(RELEASE_WORKFLOW.read, "Update release notes")
    stub = <<~'SH'
      gh() {
        if [[ "$2" == --method ]]; then
          printf '%s\n' "$@" > "${RUNNER_TEMP}/patch-arguments"
        else
          printf 'true\t%s\n' "${COMMIT_SHA}"
        fi
      }
    SH
    stdout, stderr, status = capture({ "RUNNER_TEMP" => @directory.to_s, "REPOSITORY" => @metadata["repository"],
                                      "COMMIT_SHA" => @metadata["commit"] }, "/bin/bash", "-euo", "pipefail", "-c", stub + block)
    assert status.success?, stdout + stderr
    arguments = (@directory / "patch-arguments").read.lines.map(&:chomp)
    assert_includes arguments, "tag_name=0.27.0"
    assert_includes arguments, "target_commitish=#{'a' * 40}"
  end
end
