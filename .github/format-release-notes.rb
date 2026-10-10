#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../scripts/lib/xml-text"

module ReleaseNotes
  SECTIONS = {
    "feat" => "What's New", "fix" => "Fixes", "perf" => "Performance", "refactor" => "Under the Hood",
    "docs" => "Documentation", "style" => "Style", "test" => "Testing"
  }.freeze
  SKIP_TYPES = %w[build ci chore].freeze
  SPACE = /[[:space:]\x1c-\x1f]/
  NON_SPACE = /[^[:space:]\x1c-\x1f]/
  PR_RE = /\A\*#{SPACE}+(?:(?<type>[a-z]+)(?:\([^)]*\))?(?<breaking>!)?:#{SPACE}*)?(?<desc>.+?)(?:#{SPACE}+by#{SPACE}+@[\p{L}\p{N}_-]+)?(?:#{SPACE}+in#{SPACE}+https?:\/\/#{NON_SPACE}+)?#{SPACE}*\z/
  CHANGELOG_RE = /\A\*\*Full Changelog\*\*:#{SPACE}*(?<url>https?:\/\/#{NON_SPACE}+)/
  HEADINGS = ["Breaking Changes", *SECTIONS.values.uniq, "Other"].freeze

  module_function

  def parse_notes(raw, strip_contributions: false)
    sections = {}
    changelog_url = nil
    raw.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
       .split(/\r\n|[\n\r\v\f\x1c-\x1e\u0085\u2028\u2029]/).each do |line|
      line = strip_space(XMLText.clean(line))
      if (changelog = CHANGELOG_RE.match(line))
        changelog_url = changelog[:url]
        next
      end
      next if strip_contributions && /made their first contribution/i.match?(line)

      entry = PR_RE.match(line)
      next unless entry
      next if SKIP_TYPES.include?(entry[:type]) && !entry[:breaking]

      section = entry[:breaking] ? "Breaking Changes" : SECTIONS.fetch(entry[:type], "Other")
      (sections[section] ||= []) << strip_space(entry[:desc])
    end
    [sections, changelog_url]
  end

  def strip_space(text)
    text.gsub(/\A#{SPACE}+|#{SPACE}+\z/, "")
  end

  def format_markdown(tag, sections, changelog_url)
    lines = ["## Brewy #{tag}", ""]
    HEADINGS.each do |heading|
      next unless sections[heading]&.any?

      lines << "### #{heading}"
      lines.concat(sections[heading].map { |entry| "- #{entry}" })
      lines << ""
    end
    lines.concat(["---", "**Full Changelog**: #{changelog_url}", ""]) if changelog_url
    lines.join("\n")
  end

  def escape_html(value)
    XMLText.clean(value).gsub(/[&<>"']/, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#x27;")
  end

  def format_html(_tag, sections, _changelog_url)
    HEADINGS.filter_map do |heading|
      next unless sections[heading]&.any?

      ["<h2>#{escape_html(heading)}</h2>", "<ul>",
       *sections[heading].map { |entry| "  <li>#{escape_html(entry)}</li>" }, "</ul>"].join("\n")
    end.join("\n")
  end

  def main(arguments)
    abort "Usage: #{$PROGRAM_NAME} <raw_notes_file> <tag> [--html]" if arguments.length < 2

    raw = File.read(arguments[0], encoding: Encoding::UTF_8)
    html = arguments.include?("--html")
    sections, changelog = parse_notes(raw, strip_contributions: html)
    output = html ? format_html(arguments[1], sections, changelog) : format_markdown(arguments[1], sections, changelog)
    $stdout.write(output + "\n")
  end
end

ReleaseNotes.main(ARGV) if $PROGRAM_NAME == __FILE__
