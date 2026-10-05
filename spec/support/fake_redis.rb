# frozen_string_literal: true

# An in-process stand-in for the few Redis commands the RedisStore sends, with the semantics of
# redis-rb 5 (sorted sets ordered by score then member, missing keys read as empty). Enough to run
# the store's behaviour specs without a server; TTLs are recorded, not enforced.
class FakeRedis
  attr_reader :ttls

  def initialize
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

  def set(key, value)
    @strings[key] = value.to_s
    "OK"
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
