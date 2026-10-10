#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

class CIPathRouting
  ROUTES = %w[lint tests probe release_helpers codeql zizmor].freeze
  attr_reader :routes

  def initialize
    @routes = ROUTES.to_h { |route| [route, false] }
  end

  def select_all
    routes.transform_values! { true }
  end

  def route(path)
    if ["scripts/ci-path-routing.rb", "Gemfile", "Gemfile.lock", ".ruby-version"].include?(path)
      select_all
      return
    end
    routed = false
    select = lambda do |*names|
      names.each { |name| routes[name] = true }
      routed = true
    end
    if path.end_with?(".swift") || path.start_with?("scripts/lib/", "Brewy/", "BrewyTests/", "BrewyUITests/", "Brewy.xcodeproj/") ||
       [".swiftlint.yml", ".github/workflows/ci.yml", "scripts/xcresult-to-junit.rb"].include?(path)
      select.call("lint", "tests")
    end
    select.call("lint") if path.end_with?(".md") || path == "_typos.toml"
    if [".github/workflows/ci.yml", ".github/workflows/release.yml", ".github/format-release-notes.rb",
        ".github/appcast-template.xml", "scripts/validate-release-helpers.rb", "scripts/release-delivery.rb",
        "scripts/xcresult-to-junit.rb"].include?(path) || path.start_with?(".githooks/", "scripts/tests/", "scripts/lib/")
      select.call("lint", "release_helpers")
    end
    if path.start_with?("Brewy/Models/", "scripts/brew-json-probe/") ||
       [".github/workflows/brew-json-probe.yml", ".github/workflows/ci.yml"].include?(path)
      select.call("probe")
    end
    select.call("codeql") if path.start_with?("Brewy/", "BrewyTests/", "BrewyUITests/")
    select.call("zizmor") if path.start_with?(".github/workflows/")
    if path.start_with?("assets/", ".github/", "scripts/", ".githooks/", ".") || ["LICENSE", "justfile"].include?(path)
      select.call("lint")
    end
    select_all unless routed
  end

  def self.validate
    ["Brewy/quoted\tinput.swift", "Brewy/newline\ninput.swift", 'Brewy/double"quote.swift',
     'Brewy/back\\slash.swift', "Brewy/non-ASCII-café.swift", "Brewy/space name.swift", "Brewy/Info.plist",
     "Brewy/Brewy.entitlements", "Brewy/AppIcon.icon/icon.json", "Brewy/AppIcon.icon/Assets/box.svg",
     "BrewyTests/Fixtures/appcast.xml", "BrewyUITests/Fixtures/screenshot.png"].each do |path|
      router = new
      router.route(path)
      raise "Source path was not routed: #{path.inspect}" unless %w[lint tests codeql].all? { |name| router.routes[name] }
    end
    ["-leading-dash", "scripts/ci-path-routing.rb", "Gemfile", "Gemfile.lock", ".ruby-version"].each do |path|
      router = new
      router.route(path)
      raise "Unknown or routing path must select all checks" unless router.routes.values.all?
    end
    { ".swiftlint.yml" => %w[lint tests], "Brewy/Models/fixture.json" => %w[lint tests probe codeql] }.each do |path, expected|
      router = new
      router.route(path)
      raise "Required routes missing for #{path}" unless router.routes.select { |_, enabled| enabled }.keys == expected
    end
    ["scripts/tests/test_cask_dco.rb", "scripts/release-delivery.rb", ".github/workflows/ci.yml",
     ".githooks/pre-push", ".githooks/commit-msg"].each do |path|
      router = new
      router.route(path)
      raise "Release helper check missing for #{path}" unless router.routes["release_helpers"]
      raise "Helper-only change selected Swift tests" if path.start_with?("scripts/") && router.routes["tests"]
    end
    router = new
    router.route("README.md")
    raise "Documentation should select only lint" unless router.routes.select { |_, enabled| enabled }.keys == ["lint"]
  end

  def self.main(arguments)
    if arguments == ["--self-test"]
      validate
      puts "CI path routing validation passed."
    elsif arguments.length == 1
      router = new
      paths = File.binread(arguments.first)
      raise "Expected NUL-terminated changed paths" unless paths.empty? || paths.end_with?("\0")

      paths.split("\0").each { |path| router.route(path) }
      puts JSON.generate(router.routes)
    else
      abort "usage: ci-path-routing.rb {CHANGED_PATHS_FILE|--self-test}"
    end
  end
end

CIPathRouting.main(ARGV) if $PROGRAM_NAME == __FILE__
