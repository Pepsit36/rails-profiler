# frozen_string_literal: true

require "strscan"

module Profiler
  # Reads a stored SQL statement the way the database would, one token at a time:
  # comments, string literals and quoted identifiers are never mistaken for keywords
  # or placeholders. Used by ExplainRunner to refuse anything but a read, and to put
  # the bind values back into the statement.
  module SqlStatement
    # The first keyword of a statement EXPLAIN may run.
    READ_ONLY_VERBS = %w[SELECT WITH TABLE VALUES].freeze

    # Keywords that make a read-only verb write or lock: a CTE that writes,
    # SELECT ... INTO (and MySQL's INTO OUTFILE), FOR UPDATE / FOR SHARE,
    # LOCK IN SHARE MODE. Matched as whole words outside literals, so a column
    # named `updated_at` is fine and an unquoted column named `share` is refused.
    WRITE_KEYWORDS = %w[INSERT UPDATE DELETE MERGE TRUNCATE DROP ALTER CREATE INTO LOCK SHARE].freeze

    Token = Struct.new(:type, :text)

    # 'it''s' everywhere; 'it\'s' too where a backslash escapes. An unterminated
    # literal runs to the end: the database refuses such a statement anyway.
    PLAIN_LITERAL = /[Nn]?'(?:[^']|'')*'?/m
    BACKSLASH_LITERAL = /[Nn]?'(?:[^'\\]|''|\\.)*'?/m
    ESCAPE_LITERAL = /[Ee]'(?:[^'\\]|''|\\.)*'?/m

    # Dialects differ in what a literal or a comment is: a backslash escapes a quote
    # in every MySQL string but only in PostgreSQL's E'...' strings, dollar quoting
    # is PostgreSQL's, backticks quote identifiers in MySQL and SQLite, MySQL starts
    # a comment with `#` and needs a space after `--`, and only PostgreSQL nests
    # block comments.
    DIALECTS = %i[postgresql mysql sqlite].freeze

    # @param dialect [Symbol] one of DIALECTS
    # @return [String, nil] why the statement must not be explained, or nil when it reads only
    def self.read_only_refusal(sql, dialect:)
      all = tokenize(sql, dialect)
      if dialect == :mysql && all.any? { |t| t.type == :comment && t.text.start_with?("/*!") }
        return refusal("it holds a MySQL executable comment (/*! ... */)")
      end

      tokens = all.reject { |t| %i[space comment].include?(t.type) }
      first = tokens.find { |t| t.type != :punct || t.text != "(" }
      return refusal("it is empty") if first.nil?

      verb = first.text.upcase
      return refusal("it starts with #{verb}") unless first.type == :word && READ_ONLY_VERBS.include?(verb)

      tokens.each_with_index do |token, i|
        if token.type == :word && WRITE_KEYWORDS.include?(token.text.upcase)
          return refusal("it contains #{token.text.upcase}")
        end
        if token.type == :punct && token.text == ";" && i != tokens.size - 1
          return refusal("it holds more than one statement")
        end
      end
      nil
    end

    # Replaces each placeholder by its quoted value in a single pass: `$1`, `$10`...
    # by number (PostgreSQL), or `?` in order (MySQL, SQLite). Placeholders inside
    # literals or comments stay as they are, and a substituted value is never read
    # again. A placeholder without a value is left in place.
    def self.substitute(sql, binds, dialect:, &quote)
      return sql if binds.empty?

      position = 0
      tokenize(sql, dialect).map do |token|
        index = case token.type
                when :numbered then token.text[1..].to_i - 1
                when :question then (position += 1) - 1
                end
        index && index >= 0 && index < binds.size ? quote.call(binds[index]) : token.text
      end.join
    end

    def self.refusal(reason)
      "EXPLAIN refused: only read-only statements (SELECT, WITH ... SELECT, TABLE, VALUES) " \
        "are explained, and #{reason}. PostgreSQL's EXPLAIN ANALYZE runs the statement it explains."
    end

    # Splits the statement into tokens whose texts, joined, give it back unchanged.
    def self.tokenize(sql, dialect)
      raise ArgumentError, "unknown SQL dialect: #{dialect.inspect}" unless DIALECTS.include?(dialect)

      s = StringScanner.new(sql.to_s)
      tokens = []
      until s.eos?
        tokens << if s.scan(/\s+/)
          Token.new(:space, s.matched)
        elsif s.scan(dialect == :mysql ? /(?:--(?=\s|\z)|#)[^\n]*/ : /--[^\n]*/)
          Token.new(:comment, s.matched)
        elsif s.check(%r{/\*})
          Token.new(:comment, scan_block_comment(s, nested: dialect == :postgresql))
        elsif s.scan(dialect == :mysql ? BACKSLASH_LITERAL : PLAIN_LITERAL) ||
              (dialect == :postgresql && s.scan(ESCAPE_LITERAL))
          Token.new(:literal, s.matched)
        elsif s.scan(/"(?:[^"]|"")*"?/m) || (dialect != :postgresql && s.scan(/`(?:[^`]|``)*`?/m))
          Token.new(:identifier, s.matched)
        elsif dialect == :postgresql && s.scan(/\$\d+/)
          Token.new(:numbered, s.matched)
        elsif dialect == :postgresql && s.scan(/\$([A-Za-z_][A-Za-z0-9_]*)?\$/)
          tag = s.matched
          body = s.scan_until(/#{Regexp.escape(tag)}/) || s.rest.tap { s.terminate }
          Token.new(:literal, tag + body)
        elsif dialect != :postgresql && s.scan(/\?/)
          Token.new(:question, s.matched)
        elsif s.scan(/[A-Za-z_][A-Za-z0-9_$]*/)
          Token.new(:word, s.matched)
        else
          Token.new(:punct, s.getch)
        end
      end
      tokens
    end

    # An unterminated block comment runs to the end.
    def self.scan_block_comment(s, nested:)
      text = +""
      depth = 0
      until s.eos?
        if s.scan(%r{/\*})
          depth += 1 if nested || depth.zero?
        elsif s.scan(%r{\*/})
          depth -= 1
        else
          s.getch
        end
        text << s.matched
        break if depth.zero?
      end
      text
    end

    private_class_method :refusal, :tokenize, :scan_block_comment
  end
end
