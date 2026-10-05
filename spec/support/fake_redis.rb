# frozen_string_literal: true

# An in-process stand-in for the few Redis commands the RedisStore sends, with the semantics of
# redis-rb 5 (sorted sets ordered by score then member, missing keys read as empty). Enough to run
# the store's behaviour specs without a server; TTLs are recorded, not enforced.
class FakeRedis
  attr_reader :ttls, :round_trips

  def initialize
    @round_trips = 0
    @strings = {}
    @zsets = Hash.new { |h, k| h[k] = {} }
    @sets = Hash.new { |h, k| h[k] = [] }
    @ttls = {}
  end

  def setex(key, ttl, value)
    @strings[key] = value.to_s
    @ttls[key] = ttl
    "OK"
  end

  def set(key, value, nx: false, ex: nil)
    return false if nx && @strings.key?(key)

    @strings[key] = value.to_s
    @ttls[key] = ex if ex
    nx ? true : "OK"
  end

  # The only script the store sends: delete KEYS[1] if it still holds ARGV[1].
  def eval(script, keys: [], argv: [])
    raise ArgumentError, "unknown script" unless script.include?("get") && script.include?("del")

    @strings[keys.first] == argv.first.to_s ? (@strings.delete(keys.first) ? 1 : 0) : 0
  end

  # One round trip for the whole block, as redis-rb sends a pipeline.
  def pipelined
    @in_pipeline = true
    yield self
  ensure
    @in_pipeline = false
  end

  def get(key)
    @strings[key]
  end

  def mget(*keys)
    keys.flatten.map { |k| @strings[k] }
  end

  def exists?(key)
    @strings.key?(key) || (@zsets.key?(key) && !@zsets[key].empty?) || (@sets.key?(key) && !@sets[key].empty?)
  end

  def expire(key, ttl)
    @ttls[key] = ttl
    true
  end

  def del(*keys)
    keys.flatten.count do |k|
      [@strings.delete(k), @zsets.delete(k), @sets.delete(k)].any? { |v| v && !(v.respond_to?(:empty?) && v.empty?) }
    end
  end

  def keys(pattern = "*")
    regex = Regexp.new("\\A#{Regexp.escape(pattern).gsub('\*', '.*')}\\z")
    (@strings.keys + @zsets.keys + @sets.keys).uniq.grep(regex)
  end

  def zadd(key, score, member)
    @zsets[key][member.to_s] = score.to_f
    true
  end

  def zrem(key, member)
    return Array(member).count { |m| !@zsets[key].delete(m.to_s).nil? } if member.is_a?(Array)

    !@zsets[key].delete(member.to_s).nil?
  end

  def zcard(key)
    @zsets.key?(key) ? @zsets[key].size : 0
  end

  def zrange(key, start, stop)
    slice(sorted(key), start, stop)
  end

  def zrevrange(key, start, stop)
    slice(sorted(key).reverse, start, stop)
  end

  def zrangebyscore(key, min, max)
    sorted(key).select { |m| in_range?(@zsets[key][m], min, max) }
  end

  def zremrangebyscore(key, min, max)
    doomed = zrangebyscore(key, min, max)
    doomed.each { |m| @zsets[key].delete(m) }
    doomed.size
  end

  def sadd(key, member)
    return false if @sets[key].include?(member.to_s)

    @sets[key] << member.to_s
    true
  end

  def srem(key, member)
    !@sets[key].delete(member.to_s).nil?
  end

  def smembers(key)
    @sets.key?(key) ? @sets[key].dup : []
  end

  instance_methods(false).each do |name|
    next if %i[ttls round_trips pipelined].include?(name)

    original = instance_method(name)
    define_method(name) do |*args, **kwargs, &block|
      @round_trips += 1 unless @in_pipeline
      original.bind(self).call(*args, **kwargs, &block)
    end
  end

  private

  def sorted(key)
    return [] unless @zsets.key?(key)

    @zsets[key].sort_by { |member, score| [score, member] }.map(&:first)
  end

  def slice(members, start, stop)
    size = members.size
    start += size if start.negative?
    stop += size if stop.negative?
    start = 0 if start.negative?
    return [] if start >= size || stop < start

    members[start..[stop, size - 1].min]
  end

  def in_range?(score, min, max)
    bound(min) <= score && score <= bound(max)
  end

  def bound(value)
    case value.to_s
    when "-inf" then -Float::INFINITY
    when "+inf", "inf" then Float::INFINITY
    else value.to_f
    end
  end
end
