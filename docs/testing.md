# Tests

The profiler records one profile per test (RSpec or Minitest) with its SQL queries, cache
operations, exception and timing, and can run your tests from the dashboard or from an AI
assistant over MCP.

## Test profiling

When `config.track_tests = true` (the default in the `test` environment), the profiler wraps
every test you hook it into and captures SQL queries, cache operations, exceptions, timing and a
flame graph.

**RSpec**: add to `spec/spec_helper.rb` or `spec/rails_helper.rb`:

```ruby
require 'profiler/test_helpers/rspec_support'

RSpec.configure do |config|
  Profiler::TestHelpers::RSpecSupport.install(config)
end
```

> **Known issue in 0.32.1.** Under RSpec 3.13, `RSpecSupport.install` makes every example fail
> with `NoMethodError: undefined method 'line_number'`: the object an `around` hook receives does
> not answer it. Until it is fixed, set the hook up yourself, reading the line from the metadata:
>
> ```ruby
> require 'profiler/test_helpers/rspec_support'
>
> RSpec.configure do |config|
>   config.around(:each) do |example|
>     Profiler::TestProfiler.profile(test_name: example.full_description, test_file: example.file_path,
>                                    test_line: example.metadata[:line_number], framework: :rspec) { example.run }
>   end
>   config.after(:suite) { Profiler::TestHelpers::Reporter.print }
> end
> ```
>
> With either form, a failing or pending example is recorded, and counted in the report, as
> passed: the status is read before RSpec has set it.

**Minitest**: add to `test/test_helper.rb`:

```ruby
require 'profiler/test_helpers/minitest_support'
Profiler::TestHelpers::MinitestSupport.install
```

After the suite runs, a summary is printed to stdout:

```
┌─ Profiler Test Report ────────────────────────────────────────┐
│ 42 tests · 40 passed · 1 failed · 1 pending                   │
│ Total: 3420ms · 187 queries · 2 N+1 detected                  │
├─ Slowest tests ────────────────────────────────────────────────┤
│  1. UserSpec#creates a user with associations   820ms  12q ⚠ N+1 │
...
```

Test profiles are stored like HTTP profiles. With the default storage (the file store under
`tmp/rails-profiler`, in both `development` and `test`), the development server sees the profiles
of a suite run from the shell: they are listed under **Tests** at `/_profiler` (see the
[UI Guide](ui.md#test-profiles)), and the MCP tools `query_test_profiles`, `get_test_profile` and
`run_tests` read them. In the test environment there is no cap on the number of profiles, so that
the report at the end of a suite sees all of them (see [Storage](storage.md#how-many-profiles-are-kept)).

![The profile of one test, Database tab](screenshots/test-profile-database.png)

## Test runner

![The Test Runner section after a run](screenshots/test-runner.png)

The dashboard page `/_profiler/test_runner` and the MCP tool `run_tests` run your tests with
`bundle exec rspec` (or `rails test`), in the `test` environment. They only run the files the
profiler discovers, `spec/**/*_spec.rb` and `test/**/*_test.rb` under the Rails root, optionally
with a line number (`spec/models/user_spec.rb:12`). Paths are compared after resolving symbolic
links, so a link to any other file is refused, and so is a discovered link whose target leaves the
Rails root. A refused selection answers `422` with the refused paths, or a tool error over MCP,
and nothing is started.

The test process starts from the environment the shell gave Rails, copied when the gem is
loaded, with the `test` environment. Environment overrides set from the profiler (the env vars
page, the MCP tool `set_env_var`) are applied on top, except those that would make the test process,
or the shell shims that start it (rbenv, asdf), load or run other code: for those, the test process
keeps the shell value, or none, and a warning names them once. They are: any name that is not
made of letters, digits and `_`; every name starting with `RUBY`, `GEM_`, `BUNDLE_`, `BUNDLER_`,
`LD_`, `DYLD_`, `BASH_`, `RBENV_`, `ASDF_`, `RVM_`, `CHRUBY`, `GIT_`, `BOOTSNAP_`, `PYTHON` or
`PERL5`; and `GEMRC`, `NODE_OPTIONS`, `NODE_PATH`, `SPEC_OPTS`, `TESTOPTS`, `TEST`, `PATH`, `HOME`,
`XDG_CONFIG_HOME`, `SHELLOPTS`, `BASHOPTS`, `PS4`, `ENV`, `CDPATH` and `IFS`. `DATABASE_URL` and
`SECRET_KEY_BASE` keep their shell value too, and `RAILS_ENV` and `RACK_ENV` are always `test`.
This is a deny list, so it cannot be complete. When your tests need one of these variables, set it
in the shell that starts Rails: the test process inherits it. Variables the application itself
writes into `ENV` once loaded (`dotenv` for instance) do not reach the test process, which loads
them on its own when your test setup does.

The test process boots your application too: the runner sets `PROFILER_TEST_RUNNER_CHILD=1` in
its environment so that it does not replay the overrides itself, and the env tools refuse that name.

The copy of the environment is taken once, when the gem is loaded. Two cases keep an older copy:

- After a hot restart of Puma (`pumactl restart`, `SIGUSR2`), the new server inherits the
  environment of the old one, overrides included, and copies that. Stop the server and start it
  again from the shell.
- Under Spring, the copy is taken when Spring preloads the application. Run `bin/spring stop`
  after changing the shell environment.

To run any file under the Rails root again, as the test runner did before:

```ruby
config.test_runner_allow_undiscovered_files = true
```

