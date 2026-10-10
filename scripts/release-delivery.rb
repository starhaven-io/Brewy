#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "rexml/document"
require "tmpdir"
require_relative "lib/xml-text"

module ReleaseDelivery
  SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

  class CommandError < StandardError; end

  module_function

  def require_valid(condition, message)
    raise ArgumentError, message unless condition
  end

  def version(value)
    require_valid(value.is_a?(String) && /\A[0-9]+\.[0-9]+\.[0-9]+\z/.match?(value), "Expected a numeric release version")
    value.split(".").map(&:to_i)
  end

  def build_number(value)
    require_valid(value.is_a?(String) && /\A[1-9][0-9]*\z/.match?(value), "Expected a positive integer build number")
    value.to_i
  end

  def feed(path)
    source = File.binread(path).force_encoding(Encoding::UTF_8)
    document = REXML::Document.new(XMLText.validate!(source))
    require_valid(document.doctype.nil?, "Appcast must not contain a document type")
    # Character references are expanded only after parsing.
    document.elements.each("//*") do |element|
      element.texts.each { |text| XMLText.validate!(text.value) }
      element.attributes.each_attribute { |attribute| XMLText.validate!(attribute.value) }
    end
    channels = document.root.elements.select { |element| element.name == "channel" && element.namespace.empty? }
    items = channels.flat_map do |channel|
      channel.elements.select { |element| element.name == "item" && element.namespace.empty? }
    end
    require_valid(items.length == 1, "Expected one release in the appcast")
    item = items.first
    tag = REXML::XPath.first(item, "sparkle:shortVersionString", { "sparkle" => SPARKLE })&.text.to_s
    build = REXML::XPath.first(item, "sparkle:version", { "sparkle" => SPARKLE })&.text.to_s
    version(tag)
    build_number(build)
    enclosure = item.elements.find { |element| element.name == "enclosure" && element.namespace.empty? }
    [tag, build, enclosure]
  end

  def check_version(tag, build, current)
    current_tag, current_build = feed(current)
    require_valid((version(tag) <=> version(current_tag)) == 1, "Release version must increase")
    require_valid(build_number(build) > build_number(current_build), "Build number must increase")
  end

  def check_feed(incoming, current)
    tag, build = feed(incoming)
    return if File.binread(incoming) == File.binread(current)

    check_version(tag, build, current)
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def expected_metadata
    metadata = { "repository" => "GITHUB_REPOSITORY", "commit" => "GITHUB_SHA",
                 "tag" => "TAG", "build" => "BUILD_NUMBER" }.transform_values { |name| ENV.fetch(name) }
    version(metadata["tag"])
    build_number(metadata["build"])
    require_valid(/\A[0-9a-f]{40}\z/.match?(metadata["commit"]), "Invalid source commit")
    metadata["asset"] = "Brewy-#{metadata['tag']}.zip"
    metadata
  end

  def validate_manifest(directory, metadata)
    expected = expected_metadata
    require_valid(expected.all? { |key, value| metadata[key] == value },
                  "Delivery metadata does not match this workflow's source and version")
    require_valid(metadata["sha256"].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(metadata["sha256"]), "Invalid asset digest")
    require_valid(metadata["release_id"].is_a?(Integer) && metadata["release_id"].positive?, "Invalid release ID")
    appcast = Pathname(directory) / "appcast.xml"
    require_valid(sha256(appcast) == metadata["appcast_sha256"], "Appcast digest changed")
    tag, build, enclosure = feed(appcast)
    require_valid([tag, build] == metadata.values_at("tag", "build"), "Appcast version mismatch")
    require_valid(!enclosure.nil?, "Missing appcast enclosure")
    url = "https://github.com/#{metadata['repository']}/releases/download/#{tag}/#{metadata['asset']}"
    require_valid(enclosure.attributes.get_attribute_ns("", "url")&.value == url, "Appcast download URL mismatch")
    require_valid(metadata["length"].is_a?(Integer) && metadata["length"].positive? &&
                  enclosure.attributes.get_attribute_ns("", "length")&.value == metadata["length"].to_s, "Appcast length mismatch")
    signature = enclosure.attributes.get_attribute_ns(SPARKLE, "edSignature")
    require_valid(signature && !signature.value.empty?, "Missing Sparkle signature")
  end

  def prepare(directory)
    directory = Pathname(directory)
    metadata = expected_metadata.merge(
      "sha256" => ENV.fetch("ARTIFACT_SHA256"), "length" => Integer(ENV.fetch("SPARKLE_LENGTH"), 10),
      "release_id" => Integer(ENV.fetch("RELEASE_ID"), 10), "appcast_sha256" => sha256(directory / "appcast.xml")
    )
    validate_manifest(directory, metadata)
    (directory / "delivery.json").write(JSON.generate(metadata) + "\n")
  end

  def run(arguments, token: nil, output: nil)
    environment = token.nil? ? {} : { "GH_TOKEN" => token }
    if output
      Open3.popen3(environment, *arguments) do |stdin, stdout, stderr, process|
        stdin.close
        errors = Thread.new { stderr.read }
        IO.copy_stream(stdout, output)
        [nil, errors.value, process.value.exitstatus]
      end
    else
      stdout, stderr, status = Open3.capture3(environment, *arguments)
      [stdout.force_encoding(Encoding::UTF_8), stderr.force_encoding(Encoding::UTF_8), status.exitstatus]
    end
  end

  def gh(*arguments, token: nil, output: nil)
    stdout, _stderr, status = run(["gh", *arguments], token: token, output: output)
    raise CommandError, "GitHub CLI failed (exit #{status})" unless status == 0

    stdout
  end

  def tag_commit(repository, tag)
    stdout, _stderr, status = run(["gh", "api", "--include", "repos/#{repository}/git/ref/tags/#{tag}"])
    # Only a confirmed 404 means no tag; authorization and network failures stop publication.
    response = /\AHTTP\/\S+ (\d{3})\b/.match(stdout)
    require_valid(!response.nil?, "Could not determine release tag status")
    return nil if response[1] == "404"

    require_valid(response[1] == "200" && status == 0, "Could not read release tag")
    JSON.parse(gh("api", "repos/#{repository}/commits/#{tag}")).fetch("sha")
  end

  def release_state(metadata, allow_draft:, token: nil)
    repository, tag = metadata.values_at("repository", "tag")
    release = JSON.parse(gh("api", "repos/#{repository}/releases/#{metadata['release_id']}", token: token))
    require_valid(release.fetch("id") == metadata["release_id"], "Release identity changed")
    require_valid(release.fetch("tag_name") == tag && release.fetch("target_commitish") == metadata["commit"],
                  "Release targets a different source commit")
    require_valid(release.fetch("prerelease") == false, "Refusing to distribute a prerelease")
    require_valid(allow_draft || release.fetch("draft") == false, "Release is not published")
    commit = tag_commit(repository, tag)
    require_valid((release.fetch("draft") == true && commit.nil?) ||
                  (release.fetch("draft") == false && commit == metadata["commit"]), "Release tag binding changed")
    assets = release.fetch("assets").select { |asset| asset.fetch("name") == metadata["asset"] }
    require_valid(assets.length == 1 && assets.first.fetch("size") == metadata["length"] &&
                  assets.first.fetch("digest") == "sha256:#{metadata['sha256']}", "Release asset mismatch")
    require_valid(assets.first["id"].is_a?(Integer) && assets.first["id"].positive?, "Invalid release asset ID")
    [release, assets.first]
  end

  def verify(directory, publish: false)
    directory = Pathname(directory)
    metadata = JSON.parse((directory / "delivery.json").read(encoding: Encoding::UTF_8))
    validate_manifest(directory, metadata)
    release_token = publish ? ENV.fetch("GH_PUBLISH_TOKEN") : nil
    _, hosted_asset = release_state(metadata, allow_draft: publish, token: release_token)
    repository = metadata["repository"]
    Dir.mktmpdir("brewy-delivery-") do |temporary|
      asset = Pathname(temporary) / metadata["asset"]
      asset.open("wb") do |output|
        gh("api", "repos/#{repository}/releases/assets/#{hosted_asset['id']}",
           "--header", "Accept: application/octet-stream", token: release_token, output: output)
      end
      require_valid(asset.size == metadata["length"] && sha256(asset) == metadata["sha256"],
                    "Release bytes differ from the prepared, signed archive")
      gh("attestation", "verify", asset.to_s, "--repo", repository,
         "--signer-workflow", "#{repository}/.github/workflows/release.yml",
         "--source-digest", metadata["commit"], "--source-ref", "refs/heads/main",
         "--deny-self-hosted-runners")
    end
    release, current_asset = release_state(metadata, allow_draft: publish, token: release_token)
    require_valid(current_asset["id"] == hosted_asset["id"], "Release asset identity changed during verification")
    if publish && release["draft"]
      # GitHub detaches a draft from its tag when an edit omits tag_name.
      gh("api", "repos/#{repository}/releases/#{metadata['release_id']}", "--method", "PATCH", "-F", "draft=false",
         "-f", "tag_name=#{metadata['tag']}", "-f", "target_commitish=#{metadata['commit']}", token: release_token)
    end
    release_state(metadata, allow_draft: false, token: release_token)
  end

  def main(arguments)
    command, *values = arguments
    case [command, values.length]
    when ["prepare", 1] then prepare(values.first)
    when ["verify", 1], ["publish", 1] then verify(values.first, publish: command == "publish")
    when ["check-version", 3] then check_version(*values)
    when ["check-feed", 2] then check_feed(*values)
    else
      abort "usage: release-delivery.rb {prepare|verify|publish} DIRECTORY | check-version TAG BUILD CURRENT | check-feed INCOMING CURRENT"
    end
  end
end

ReleaseDelivery.main(ARGV) if $PROGRAM_NAME == __FILE__
