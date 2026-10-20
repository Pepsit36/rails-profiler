# frozen_string_literal: true

module Profiler
  module Alerts
    # Removes from a SQL statement what the shared N1Patterns.normalize_sql lets through: strings
    # with a backslash escape or a doubled quote, double quoted text, comments and dollar-quoted
    # bodies. Used for alerts only; the shared normalization is left as it is.
    #
    # The statement is read twice, with backslash escapes (MySQL) and without (standard SQL). When
    # the two readings disagree, or a quote or a comment opener is left, the statement is cut at
    # the first one: a value is dropped rather than guessed. A literal in a vendor syntax not
    # listed here can still remain, hence also the cut at SQL_LIMIT in Alerts.
    module SqlRedaction
      STRINGS_WITH_BACKSLASH = /'(?:[^'\\]|\\.|'')*'|"(?:[^"\\]|\\.|"")*"/m
      STRINGS_STANDARD = /'(?:[^']|'')*'|"(?:[^"]|"")*"/m
      DOLLAR_QUOTED = /\$(?<tag>[A-Za-z_]\w*|)\$.*?\$\k<tag>\$/m
      COMMENTS = %r{/\*.*?\*/|--[^\n]*|(?<=\s|\A)\#[^\n]*}m
      # Tried left to right, so a quote in a comment, or a comment in a quote, is not read as the other.
      READINGS = [STRINGS_WITH_BACKSLASH, STRINGS_STANDARD].map do |strings|
        Regexp.union(strings, DOLLAR_QUOTED, COMMENTS)
      end.freeze
      # What is left of a literal or a comment when a form was not read to its end.
      OPENER = %r{['"]|/\*|--|\$(?:[A-Za-z_]\w*)?\$|(?<=\s|\A)#}

      module_function

      def redact(sql)
        readings = READINGS.map { |pattern| sql.gsub(pattern) { |m| m.start_with?("'", '"') ? "?" : " " } }
        return sql[0, sql.index(OPENER) || sql.length] if readings.uniq.size > 1 || readings.first.match?(OPENER)

        readings.first
      end
    end
  end
end
