# frozen_string_literal: true

module Profiler
  # Tells a body that is text from one that is not, from the bytes themselves and not only from
  # the Content-Type the sender declared: a binary payload served as text/plain is common, and
  # forcing it into UTF-8 loses bytes it cannot get back.
  module BodyContent
    BINARY_CONTENT_TYPES = %r{
      \A(?:image/(?!svg)|audio/|video/|font/|
        application/(?:pdf|octet-stream|zip|gzip|x-gzip|x-protobuf|protobuf|x-msgpack|msgpack|
                       wasm|x-font|font-|vnd\.ms-fontobject|x-tar|x-7z-compressed|x-bzip2|zstd))
    }xi

    # Enough to tell: the head of a body is where a magic number or a NUL byte shows up.
    SAMPLE_BYTES = 8192
    # A text holds few control characters: tab, newline, carriage return and escape set aside.
    MAX_CONTROL_RATIO = 0.05

    module_function

    def binary_type?(content_type)
      content_type.to_s.split(";").first.to_s.strip.match?(BINARY_CONTENT_TYPES)
    end

    # True for a body that cannot be kept as text: a NUL byte, bytes that are not UTF-8 (a cut
    # in the middle of the last character excepted), or mostly control characters.
    def binary_bytes?(body)
      return false if body.nil? || body.empty?

      sample = body.byteslice(0, SAMPLE_BYTES).dup.force_encoding(Encoding::UTF_8)
      return true if sample.include?("\0")

      unless sample.valid_encoding?
        # The sample may end inside a multi-byte character, whichever way it was cut.
        sample = (1..3).filter_map { |n| sample.byteslice(0, sample.bytesize - n)&.force_encoding(Encoding::UTF_8) }
                       .find(&:valid_encoding?)
        return true if sample.nil?
      end

      controls = sample.count("\x01-\x08\x0B\x0C\x0E-\x1A\x1C-\x1F\x7F")
      sample.length.positive? && controls.fdiv(sample.length) > MAX_CONTROL_RATIO
    end

    def binary?(body, content_type)
      binary_type?(content_type) || binary_bytes?(body)
    end
  end
end
