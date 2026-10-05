# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Profiler
  module Storage
    # Creates the profiler's directories and files readable by the process user only (0700 and
    # 0600), whatever the umask: profiles hold cookies, tokens and environment values. A directory
    # that already exists keeps its mode. config.restrict_storage_permissions = false leaves the
    # modes to the umask, for a web process and workers running under two users.
    module PrivateFiles
      DIR_MODE = 0o700
      FILE_MODE = 0o600
      # Where the platform has it: a symbolic link placed where the profiler expects its own file
      # is not followed (ELOOP) instead of being written through.
      NOFOLLOW = defined?(File::NOFOLLOW) ? File::NOFOLLOW : 0

      @warned = {}
      @warn_mutex = Mutex.new

      module_function

      def restricted?
        Profiler.configuration.restrict_storage_permissions ? true : false
      end

      # Creates the missing parents with the umask's mode, so that the application's own
      # directories (tmp/ for instance) are left as they would be, and the directory itself 0700.
      def mkdir(path)
        path = path.to_s
        return if File.directory?(path)
        return FileUtils.mkdir_p(path) unless restricted?

        FileUtils.mkdir_p(File.dirname(path))
        begin
          Dir.mkdir(path, DIR_MODE)
          File.chmod(DIR_MODE, path)
        rescue Errno::EEXIST
          raise unless File.directory?(path)
        end
      end

      # A directory under tmp_path, created with tmp_path itself as #mkdir creates a directory.
      def tmp_dir(*parts)
        dir = Profiler.configuration.tmp_path
        mkdir(dir)
        warn_if_shared(dir)
        parts.each do |part|
          dir = dir.join(part)
          mkdir(dir)
        end
        dir
      end

      # Writes to a temporary file next to path then renames it over path: a reader never sees a
      # half-written file, and the file has its mode from the start, even when it replaces an
      # older one with a wider mode.
      def write(path, data)
        path = path.to_s
        tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp")
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, new_file_mode) do |file|
          file.chmod(FILE_MODE) if restricted?
          file.write(data)
        end
        File.rename(tmp, path)
        tmp = nil
        path
      ensure
        FileUtils.rm_f(tmp) if tmp
      end

      # Opens path for reading and writing, creating it 0600 when missing.
      def open(path, &block)
        File.open(path.to_s, File::RDWR | File::CREAT | NOFOLLOW, new_file_mode, &block)
      end

      # Creates an empty file 0600 when missing, or brings an existing one back to 0600.
      def touch(path)
        path = path.to_s
        refuse_link(path)
        File.open(path, File::WRONLY | File::CREAT | NOFOLLOW, new_file_mode) { |file| file.chmod(FILE_MODE) if restricted? }
      end

      # Brings an existing file back to 0600; a missing one is left missing.
      def restrict(path)
        path = path.to_s
        refuse_link(path)
        File.chmod(FILE_MODE, path) if restricted? && File.exist?(path)
      end

      # A symbolic link where the profiler keeps a file of its own would make it change the mode of
      # (and write to) whatever the link points at. Refused while the permissions are restricted.
      def refuse_link(path)
        return unless restricted? && File.symlink?(path)

        raise Profiler::Error, "Refusing to use #{path}: it is a symbolic link, where the profiler expects " \
                               "a file of its own. Remove it, or set config.restrict_storage_permissions = false."
      end

      # Says once per directory when an existing tmp_path belongs to another user or can be written
      # to by others (tmp/rails-profiler under a shared /tmp, outside Rails): they could place files
      # or links there before the profiler does.
      def warn_if_shared(dir)
        return unless restricted?

        stat = File.stat(dir.to_s)
        return if stat.uid == Process.euid && (stat.mode & 0o022).zero?

        key = dir.to_s
        first = @warn_mutex.synchronize { @warned[key] ? false : (@warned[key] = true) }
        return unless first

        warn "[Profiler] tmp_path #{key} belongs to another user or is writable by group or others " \
             "(mode #{format("%o", stat.mode & 0o777)}): other local users could place files there. Set " \
             "config.tmp_path to a directory of your own, or run chmod 700 on it."
      rescue SystemCallError
        nil
      end

      def reset_warnings!
        @warn_mutex.synchronize { @warned = {} }
      end

      def new_file_mode
        restricted? ? FILE_MODE : 0o666
      end
    end
  end
end
