# frozen_string_literal: true

require_relative "test_helper"
require_relative "../../.github/format-release-notes"
require_relative "../release-delivery"

class ReleaseNotesTests < Minitest::Test
  include HelperTestSupport

  def setup
    @raw = <<~NOTES
      ## What's Changed
      * feat(ui): render <trusted> & ]]> <evil> state by @contributor in https://github.com/starhaven-io/Brewy/pull/1
      * fix: preserve an apostrophe's meaning by @contributor in https://github.com/starhaven-io/Brewy/pull/2
      * feat(api)!: require a new format by @contributor in https://github.com/starhaven-io/Brewy/pull/5
      * build!: raise minimum macOS by @contributor in https://github.com/starhaven-io/Brewy/pull/6
      * ci!: change release consumers by @contributor in https://github.com/starhaven-io/Brewy/pull/7
      * ci: internal-only change by @contributor in https://github.com/starhaven-io/Brewy/pull/3
      * uncategorized improvement by @contributor in https://github.com/starhaven-io/Brewy/pull/4
      **Full Changelog**: https://github.com/starhaven-io/Brewy/compare/0.1.0...0.2.0
    NOTES
    @sections, @changelog = ReleaseNotes.parse_notes(@raw)
  end

  def test_categories_breaking_changes_and_escaping
    assert_equal({ "What's New" => ["render <trusted> & ]]> <evil> state"], "Fixes" => ["preserve an apostrophe's meaning"],
                   "Other" => ["uncategorized improvement"], "Breaking Changes" => ["require a new format", "raise minimum macOS", "change release consumers"] }, @sections)
    assert_equal "https://github.com/starhaven-io/Brewy/compare/0.1.0...0.2.0", @changelog
    markdown = ReleaseNotes.format_markdown("0.2.0", @sections, @changelog)
    refute_includes markdown, "internal-only change"
    assert_includes markdown, "## Brewy 0.2.0"
    assert_operator markdown.index("### Breaking Changes"), :<, markdown.index("### What's New")
    html = ReleaseNotes.format_html("0.2.0", @sections, @changelog)
    assert_includes html, "&lt;trusted&gt; &amp; ]]&gt; &lt;evil&gt; state"
    refute_includes html, "<trusted>"
    assert html.start_with?("<h2>Breaking Changes</h2>")
    refute_includes html, "]]>"
    assert_equal "&quot;&#x27;&amp;&lt;&gt;", ReleaseNotes.escape_html("\"'&<>")
  end

  def test_formatter_cli_preserves_markdown_newlines
    Dir.mktmpdir("brewy-notes-test-") do |directory|
      notes = File.join(directory, "notes.md")
      File.write(notes, "* fix: preserve output\n")
      stdout, stderr, status = capture(RbConfig.ruby, (ROOT / ".github/format-release-notes.rb").to_s, notes, "1.2.3")
      assert status.success?, stderr
      assert_equal "## Brewy 1.2.3\n\n### Fixes\n- preserve output\n\n", stdout
    end
  end

  def test_first_contributions_are_omitted_only_from_html
    raw = "* @someone made their first contribution in https://github.com/starhaven-io/Brewy/pull/8\n"
    refute_empty ReleaseNotes.parse_notes(raw).first
    assert_empty ReleaseNotes.parse_notes(raw, strip_contributions: true).first
  end

  def test_unicode_whitespace_line_breaks_and_authors_match_original_output
    ["\n", "\r\n", "\r", "\v", "\f", "\x1c", "\x1d", "\x1e", "\u0085", "\u2028", "\u2029"].each do |separator|
      raw = "* feat: first#{separator}* fix: second#{separator}"
      assert_equal({ "What's New" => ["first"], "Fixes" => ["second"] }, ReleaseNotes.parse_notes(raw).first)
    end
    ["\t", "\u00a0", "\u1680", "\u2003", "\u202f", "\u3000"].each do |space|
      raw = "#{space}*#{space}fix:#{space}preserve café#{space}by#{space}@José#{space}in#{space}https://example.test/pr#{space}\n" \
            "**Full Changelog**:#{space}https://example.test/compare#{space}ignored"
      sections, changelog = ReleaseNotes.parse_notes(raw)
      assert_equal({ "Fixes" => ["preserve café"] }, sections)
      assert_equal "https://example.test/compare", changelog
    end
    %w[José 東京 Ⅷ ² under_score].each do |author|
      assert_equal({ "Fixes" => ["example"] }, ReleaseNotes.parse_notes("* fix: example by @#{author}").first)
    end
    ["name\u0301", "name\u203F"].each do |author|
      assert_equal({ "Fixes" => ["example by @#{author}"] }, ReleaseNotes.parse_notes("* fix: example by @#{author}").first)
    end
  end

  def test_markdown_strips_xml_invalid_controls_and_preserves_unicode
    Dir.mktmpdir("brewy-markdown-controls-") do |directory|
      notes = File.join(directory, "notes.md")
      File.write(notes, "* fix: café\0\e\uFFFE 🚀\v* fix: second\f* fix: third\x1c* fix: fourth\x1d* fix: fifth\x1e* fix: sixth\n",
                 encoding: Encoding::UTF_8)
      stdout, stderr, status = capture_c_locale(ROOT / ".github/format-release-notes.rb", notes, "1.2.3")
      assert status.success?, stderr
      assert_equal "## Brewy 1.2.3\n\n### Fixes\n- café 🚀\n- second\n- third\n- fourth\n- fifth\n- sixth\n\n", stdout
      refute XMLText::INVALID_CHARACTERS.match?(stdout)
    end
  end

  def test_appcast_rendering_preserves_xml_structure
    values = {
      "TAG" => "0.2.0", "PUBDATE" => "Wed, 02 Sep 2026 20:00:00 +0000", "BUILD_NUMBER" => "42",
      "DOWNLOAD_URL" => "https://github.com/starhaven-io/Brewy/releases/download/0.2.0/Brewy-0.2.0.zip",
      "SPARKLE_LENGTH" => "123456", "SPARKLE_SIG" => "base64-signature",
      "RELEASE_NOTES_HTML" => ReleaseNotes.format_html("0.2.0", @sections, @changelog)
    }
    # Exercise the same envsubst command that renders the published feed.
    workflow = RELEASE_WORKFLOW.read
    block = workflow_run_block(workflow, "Update appcast")
    render = block[block.index('envsubst "')..].sub(' > appcast.xml', '')
    stdout, stderr, status = capture(values, "/bin/bash", "-euo", "pipefail", "-c", render, chdir: ROOT)
    assert status.success?, stderr
    item = REXML::Document.new(stdout).elements["rss/channel/item"]
    refute_nil item
    assert_equal "0.2.0", item.elements["title"].text
    assert_equal "42", REXML::XPath.first(item, "sparkle:version", { "sparkle" => ReleaseDelivery::SPARKLE }).text
    assert_nil item.elements["evil"]
    enclosure = item.elements["enclosure"]
    assert_equal values["DOWNLOAD_URL"], enclosure.attributes["url"]
    assert_equal "123456", enclosure.attributes["length"]
    assert_equal "base64-signature", enclosure.attributes.get_attribute_ns(ReleaseDelivery::SPARKLE, "edSignature").value
  end

  def test_release_concurrency_preserves_delivery_order
    concurrency = RELEASE_WORKFLOW.read.split("concurrency:\n", 2).last.split("\n\n", 2).first
    assert_equal({ "group" => "release", "cancel-in-progress" => "false", "queue" => "max" },
                 concurrency.lines.map { |line| line.strip.split(": ", 2) }.to_h)
  end

  def test_formatter_strips_xml_invalid_characters_before_appcast_preparation
    Dir.mktmpdir("brewy-safe-notes-test-") do |directory|
      notes = File.join(directory, "notes.md")
      File.write(notes, "* feat: café\e\uFFFE 🚀\v* fix: second\f* fix: third\n", encoding: Encoding::UTF_8)
      html, stderr, status = capture_c_locale(ROOT / ".github/format-release-notes.rb", notes, "1.2.3", "--html")
      assert status.success?, stderr
      assert_includes html, "café 🚀"
      assert_includes html, "<li>second</li>"
      assert_includes html, "<li>third</li>"
      refute XMLText::INVALID_CHARACTERS.match?(html)
      values = {
        "TAG" => "1.2.3", "PUBDATE" => "Thu, 01 Oct 2026 00:00:00 +0000", "BUILD_NUMBER" => "42",
        "DOWNLOAD_URL" => "https://github.com/starhaven-io/Brewy/releases/download/1.2.3/Brewy-1.2.3.zip",
        "SPARKLE_LENGTH" => "7", "SPARKLE_SIG" => "fixture-signature", "RELEASE_NOTES_HTML" => html
      }
      xml = (ROOT / ".github/appcast-template.xml").read.gsub(/\$\{([A-Z_]+)\}/) { values.fetch(Regexp.last_match(1)) }
      File.write(File.join(directory, "appcast.xml"), xml, encoding: Encoding::UTF_8)
      _stdout, stderr, status = capture({ "GITHUB_REPOSITORY" => "starhaven-io/Brewy", "GITHUB_SHA" => "a" * 40,
                                         "TAG" => "1.2.3", "BUILD_NUMBER" => "42", "SPARKLE_LENGTH" => "7",
                                         "ARTIFACT_SHA256" => Digest::SHA256.hexdigest("archive"), "RELEASE_ID" => "42" },
                                       RbConfig.ruby, (ROOT / "scripts/release-delivery.rb").to_s, "prepare", directory)
      assert status.success?, stderr
      assert_equal "1.2.3", JSON.parse(File.read(File.join(directory, "delivery.json"))).fetch("tag")
    end
  end

  def test_xml_text_preserves_all_legal_character_ranges
    text = "\t\n\r \uD7FF\uE000\uFFFD\u{10000}\u{10FFFF}"
    assert_equal text, XMLText.clean(text)
    assert_equal text, XMLText.validate!(text)
    assert_equal "safe", XMLText.clean("safe\xFF".dup.force_encoding(Encoding::UTF_8))
    assert_equal({ "Fixes" => ["café 🚀"] }, ReleaseNotes.parse_notes("* fix: café\xFF 🚀".dup.force_encoding(Encoding::UTF_8)).first)
  end
end
