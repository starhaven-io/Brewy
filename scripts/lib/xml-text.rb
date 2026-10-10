# frozen_string_literal: true

module XMLText
  INVALID_CHARACTERS = /[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/u

  module_function

  def validate!(text)
    unless text.valid_encoding? && !INVALID_CHARACTERS.match?(text)
      raise ArgumentError, "Expected valid UTF-8 XML 1.0 characters"
    end

    text
  end

  def clean(value)
    value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
         .gsub(INVALID_CHARACTERS, "")
  end
end
