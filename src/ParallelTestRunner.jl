module ParallelTestRunner

export runtests, addworkers, addworker, find_tests, parse_args, filter_tests!

using Malt
using Dates
using Printf: @sprintf
using Base.Filesystem: path_separator
using Statistics
import Test
import Random
import IOCapture
using Test: DefaultTestSet

if VERSION >= v"1.13.0-DEV.1044"
    using Base.ScopedValues
end

include("utils.jl")
using .Utils: anynonpass, with_testset, Lockable, available_memory,
                WorkerTestSet, default_njobs, get_max_worker_rss,
                get_history_file, load_test_history, save_test_history

include("ptrworker.jl") # PTRWorker, worker_id, addworker, addworkers
include("parseargs.jl") # ParsedArgs, parse_args, filter_tests!
include("testrecord.jl") # print_test_*, runtest, memory_usage, execute, TestRecord

#
# entry point
#

"""
    find_tests(dir::String) -> Dict{String, Expr}

Discover test files in a directory and return a test suite dictionary.

Walks through `dir` and finds all `.jl` files (excluding `runtests.jl`), returning a
dictionary mapping test names to expression that include each test file.
"""
function find_tests(dir::String)
    tests = Dict{String, Expr}()
    for (rootpath, _dirs, files) in walkdir(dir)
        # find Julia files
        filter!(files) do file
            endswith(file, ".jl") && file !== "runtests.jl"
        end
        isempty(files) && continue

        # strip extension
        files = map(files) do file
            file[1:(end - 3)]
        end

        # prepend subdir
        subdir = relpath(rootpath, dir)
        if subdir != "."
            files = map(files) do file
                joinpath(subdir, file)
            end
        end

        # unify path separators
        files = map(files) do file
            replace(file, path_separator => '/')
        end

        for file in files
            path = joinpath(rootpath, basename(file * ".jl"))
            tests[file] = :(include($path))
        end
    end
    return tests
end

"""
    runtests(mod::Module, args::Union{ParsedArgs,Array{String}};
             testsuite::Dict{String,Expr}=find_tests(pwd()),
             init_code = :(),
             init_worker_code = :(),
             test_worker = Returns(nothing),
             RecordType::Type{<:AbstractTestRecord} = TestRecord,
             custom_args = (;),
             exename = nothing,
             exeflags = nothing,
             env = Vector{Pair{String, String}}(),
             stdout = Base.stdout,
             stderr = Base.stderr,
             max_worker_rss = get_max_worker_rss())
    runtests(mod::Module, ARGS; ...)

Run Julia tests in parallel across multiple worker processes.

## Arguments

- `mod`: The module calling runtests
- `ARGS`: Command line arguments.
  This can be either the vector of strings of the arguments, typically from [`Base.ARGS`](https://docs.julialang.org/en/v1/base/constants/#Base.ARGS), or a [`ParsedArgs`](@ref) object, typically constructed with [`parse_args`](@ref).
  When you run the tests with [`Pkg.test`](https://pkgdocs.julialang.org/v1/api/#Pkg.test), the command line arguments passed to the script can be changed with the `test_args` keyword argument.
  If the caller needs to accept arguments too, consider using [`parse_args`](@ref) to parse the arguments first.

Several keyword arguments are also supported:

- `testsuite`: Dictionary mapping test names to expressions to execute (default: [`find_tests(pwd())`](@ref)).
  By default, automatically discovers all `.jl` files in the test directory and its subdirectories.
- `init_code`: Code use to initialize each test's sandbox module (e.g., import auxiliary
  packages, define constants, etc).
- `init_worker_code`: Code use to initialize each worker. This is run only once per worker instead of once per test.
- `test_worker`: Optional function that takes a test name and `init_worker_code` if `init_worker_code` is defined and returns a specific worker.
  When returning `nothing`, the test will be assigned to any available default worker.
- `RecordType`: Concrete subtype of [`AbstractTestRecord`](@ref) used to collect
  per-test statistics. Defaults to [`TestRecord`](@ref). To extend the default
  record with extra data, define `struct MyRecord <: AbstractTestRecord;
  base::TestRecord; …; end` and dispatch [`execute`](@ref) on the new type —
  typically by calling `execute(TestRecord, mod, f, name, start_time,
  custom_args)` and wrapping the result. The default `print_*` methods read
  baseline fields through [`parent`](@ref), so wrapped types inherit the
  standard output; override `print_*` only when you need different layout.
  The record type must be defined on both the main process and all workers
  (e.g. via `init_worker_code`) since it crosses the Malt serialization
  boundary.
- `custom_args`: Arbitrary value (typically a `NamedTuple`) forwarded to
  [`execute`](@ref). Lets callers thread per-run configuration into a custom
  `RecordType`'s `execute` method without going through `init_code`.
- `exename`, `exeflags`, `env`: Forwarded to every internal `addworker` call, so
  they affect all default-pool workers (and any respawns). `exename` may be a
  `String` or a `Cmd` — passing a `Cmd` lets callers wrap the julia invocation
  with a tool such as `compute-sanitizer`. Custom workers created from inside a
  `test_worker` hook are the caller's responsibility.
- `stdout` and `stderr`: I/O streams to write to (default: `Base.stdout` and `Base.stderr`)
- `max_worker_rss`: RSS threshold where a worker will be restarted once it is reached.

## Command Line Options

- `--help`: Show usage information and exit
- `--list`: List all available test files and exit
- `--verbose`: Print more detailed information during test execution
- `--quickfail`: Stop the entire test run as soon as any test fails
- `--jobs=N`: Use N worker processes (default: based on CPU threads and available memory)
- `TESTS...`: Filter test files by name, matched using `startswith`

## Behavior

- Automatically discovers all `.jl` files in the test directory (excluding `runtests.jl`)
- Sorts test files by runtime (longest-running are started first) for load balancing
- Launches worker processes with appropriate Julia flags for testing
- Monitors memory usage and recycles workers that exceed memory limits
- Provides real-time progress output with timing and memory statistics
- Handles interruptions gracefully (Ctrl+C)
- Returns `nothing`, but throws `Test.FallbackTestSetException` if any tests fail

## Examples

Run all tests with default settings (auto-discovers `.jl` files)

```julia
using ParallelTestRunner
using MyPackage

runtests(MyPackage, ARGS)
```

Run only tests matching "integration" (matched with `startswith`):
```julia
using ParallelTestRunner
using MyPackage

runtests(MyPackage, ["integration"])
```

Define a custom test suite
```julia
using ParallelTestRunner
using MyPackage

testsuite = Dict(
    "custom" => quote
        @test 1 + 1 == 2
    end
)

runtests(MyPackage, ARGS; testsuite)
```

Customize the test suite
```julia
using ParallelTestRunner
using MyPackage

testsuite = find_tests(pwd())
args = parse_args(ARGS)
if filter_tests!(testsuite, args)
    # Remove a specific test
    delete!(testsuite, "slow_test")
end
runtests(MyPackage, args; testsuite)
```

## Memory Management

Workers are automatically recycled when they exceed memory limits to prevent out-of-memory
issues during long test runs. The memory limit is set based on system architecture.
"""
function runtests(mod::Module, args::ParsedArgs;
                  testsuite::Dict{String,Expr} = find_tests(pwd()),
                  init_code = :(), init_worker_code = :(), test_worker = Returns(nothing),
                  RecordType::Type{<:AbstractTestRecord} = TestRecord,
                  custom_args = (;),
                  exename = nothing,
                  exeflags = nothing,
                  env = Vector{Pair{String, String}}(),
                  stdout = Base.stdout, stderr = Base.stderr, max_worker_rss = get_max_worker_rss())
    #
    # set-up
    #

    # list tests, if requested
    if args.list !== nothing
        println(stdout, "Available tests:")
        for test in keys(testsuite)
            println(stdout, " - $test")
        end
        exit(0)
    end

    # filter tests
    filter_tests!(testsuite, args)

    # determine test order
    tests = collect(keys(testsuite))
    Random.shuffle!(tests)
    historical_durations = load_test_history(mod)
    sort!(tests, by = x -> -get(historical_durations, x, Inf))

    # determine parallelism
    jobs = something(args.jobs, default_njobs())
    jobs = clamp(jobs, 1, length(tests))
    println(stdout, "Running $(length(tests)) tests using $jobs parallel jobs. If this is too many concurrent jobs, specify the `--jobs=N` argument to the tests, or set the `JULIA_CPU_THREADS` environment variable.")
    !isnothing(args.verbose) && println(stdout, "Available memory: $(Base.format_bytes(available_memory()))")
    sem = Base.Semaphore(max(1, jobs))
    worker_pool = Channel{Union{Nothing, PTRWorker}}(jobs)
    for _ in 1:jobs
        put!(worker_pool, nothing)
    end

    t0 = time()
    results = Lockable([])
    running_tests = Lockable(Dict{String, Float64}())  # test => start_time

    worker_tasks = Task[]

    done = false
    function stop_work()
        if !done
            done = true
            for task in worker_tasks
                task == current_task() && continue
                Base.istaskdone(task) && continue
                try; schedule(task, InterruptException(); error=true); catch; end
            end
        end
    end


    #
    # output
    #

    # pretty print information about gc and mem usage
    testgroupheader = "Test"
    workerheader = "(Worker)"
    name_align = maximum(
        [
            textwidth(testgroupheader) + textwidth(" ") + textwidth(workerheader);
            map(x -> textwidth(x) + 5, tests)
        ]
    )

    print_lock = stdout isa Base.LibuvStream ? stdout.lock : ReentrantLock()
    if stderr isa Base.LibuvStream
        stderr.lock = print_lock
    end

    io_ctx = test_IOContext(RecordType, stdout, stderr, print_lock, name_align, !isnothing(args.verbose))
    print_header(RecordType, io_ctx, testgroupheader, workerheader)

    status_lines_visible = Ref(0)

    function clear_status()
        if status_lines_visible[] > 0
            for _ in 1:(status_lines_visible[]-1)
                print(io_ctx.stdout, "\033[2K")  # Clear entire line
                print(io_ctx.stdout, "\033[1A")  # Move up one line
            end
            print(io_ctx.stdout, "\r")  # Move to start of line
            status_lines_visible[] = 0
        end
    end

    function update_status()
        # take consistent snapshots once, so the rest of this function operates on
        # frozen data rather than racing with workers that mutate these collections
        running_snapshot = @lock running_tests copy(running_tests[])
        isempty(running_snapshot) && return
        results_snapshot = @lock results copy(results[])
        completed = length(results_snapshot)
        total = length(tests)

        # line 1: empty line
        line1 = ""

        # line 2: running tests
        test_list = sort(collect(keys(running_snapshot)), by = x -> running_snapshot[x])
        status_parts = map(test_list) do test
            "$test"
        end
        line2 = "Running:  " * join(status_parts, ", ")
        ## truncate
        max_width = displaysize(io_ctx.stdout)[2]
        if length(line2) > max_width
            line2 = line2[1:max_width-3] * "..."
        end

        # line 3: progress + ETA
        line3 = "Progress: $completed/$total tests completed"
        if completed > 0
            # estimate per-test time (slightly pessimistic)
            durations_done = [end_time - start_time for (_, _,_, start_time, end_time) in results_snapshot]
            μ = mean(durations_done)
            σ = length(durations_done) > 1 ? std(durations_done) : 0.0
            est_per_test = μ + 0.5σ

            est_remaining = 0.0
            ## currently-running
            for (test, start_time) in running_snapshot
                elapsed = time() - start_time
                duration = get(historical_durations, test, est_per_test)
                est_remaining += max(0.0, duration - elapsed)
            end
            ## yet-to-run
            for test in tests
                haskey(running_snapshot, test) && continue
                # Test is in any completed test
                any(r -> test == r.test, results_snapshot) && continue
                est_remaining += get(historical_durations, test, est_per_test)
            end

            eta_sec = est_remaining / jobs
            eta_mins = round(Int, eta_sec / 60)
            line3 *= " │ ETA: ~$eta_mins min"
        end

        # only display the status bar on actual terminals
        # (but make sure we cover this code in CI)
        if io_ctx.stdout isa Base.TTY
            clear_status()
            println(io_ctx.stdout, line1)
            println(io_ctx.stdout, line2)
            print(io_ctx.stdout, line3)
            flush(io_ctx.stdout)
            status_lines_visible[] = 3
        end
    end

    # Message types for the printer channel
    # (:started, test_name, worker_id)
    # (:finished, test_name, worker_id, record)
    # (:crashed, test_name, worker_id, test_time)
    printer_channel = Channel{Tuple}(100)

    printer_task = @async begin
        last_status_update = Ref(time())
        try
            while isopen(printer_channel) || isready(printer_channel)
                got_message = false
                while isready(printer_channel)
                    # Try to get a message from the channel (with timeout)
                    msg = take!(printer_channel)
                    got_message = true
                    msg_type = msg[1]

                    if msg_type == :started
                        test_name, wrkr = msg[2], msg[3]

                        # Optionally print verbose started message
                        if args.verbose !== nothing
                            clear_status()
                            print_test_started(RecordType, wrkr, test_name, io_ctx)
                        end

                    elseif msg_type == :finished
                        test_name, wrkr, record = msg[2], msg[3], msg[4]

                        clear_status()
                        if anynonpass(record[])
                            print_test_failed(record, wrkr, test_name, io_ctx)
                        else
                            print_test_finished(record, wrkr, test_name, io_ctx)
                        end

                    elseif msg_type == :crashed
                        test_name, wrkr = msg[2], msg[3]

                        clear_status()
                        print_test_crashed(RecordType, wrkr, test_name, io_ctx)
                    end
                end

                # After a while, display a status line
                if !done && time() - t0 >= 5 && (got_message || (time() - last_status_update[] >= 1))
                    update_status()
                    last_status_update[] = time()
                end

                isopen(printer_channel) && sleep(0.1)
            end
        catch ex
            if isa(ex, InterruptException)
                # the printer should keep on running,
                # but we need to signal other tasks to stop
                stop_work()
            else
                rethrow()
            end
            isa(ex, InterruptException) || rethrow()
        finally
            n_running = @lock running_tests length(running_tests[])
            n_results = @lock results length(results[])
            if n_running == 0 && n_results >= length(tests)
                # XXX: only erase the status if we completed successfully.
                #      in other cases we'll have printed "caught interrupt"
                clear_status()
            end
        end
    end

    #
    # execution
    #

    tests_to_start = Threads.Atomic{Int}(length(tests))
    try
        @sync for test in tests
            push!(worker_tasks, Threads.@spawn begin
                local p = nothing
                acquired = false
                try
                    Base.acquire(sem)
                    acquired = true
                    p = take!(worker_pool)
                    Threads.atomic_sub!(tests_to_start, 1)

                    done && return

                    test_t0 = @lock running_tests begin
                        test_t0 = time()
                        running_tests[][test] = test_t0
                    end

                    # pass in init_worker_code to custom worker function if defined
                    wrkr = if init_worker_code == :()
                        test_worker(test)
                    else
                        test_worker(test, init_worker_code)
                    end
                    if wrkr === nothing
                        wrkr = p
                    end
                    # if a worker failed, spawn a new one
                    if wrkr === nothing || !Malt.isrunning(wrkr)
                        wrkr = p = addworker(; init_worker_code, io_ctx.color,
                                             exename, exeflags, env)
                    end

                    # run the test
                    put!(printer_channel, (:started, test, worker_id(wrkr)))
                    result = try
                        Malt.remote_eval_wait(Main, wrkr.w, :(import ParallelTestRunner))
                        Malt.remote_call_fetch(invokelatest, wrkr.w, runtest,
                                               RecordType, testsuite[test], test,
                                               init_code, test_t0, custom_args)
                    catch ex
                        if isa(ex, InterruptException)
                            # the worker got interrupted, signal other tasks to stop
                            stop_work()
                            return
                        end

                        ex
                    end
                    test_t1 = time()
                    output = @lock wrkr.io String(take!(wrkr.io[]))
                    @lock results push!(results[], (; test, result, output, test_t0, test_t1))

                    # act on the results
                    if result isa AbstractTestRecord
                        put!(printer_channel, (:finished, test, worker_id(wrkr), result))
                        if anynonpass(result[]) && args.quickfail !== nothing
                            stop_work()
                            return
                        end

                        if memory_usage(result) > max_worker_rss
                            # the worker has reached the max-rss limit, recycle it
                            # so future tests start with a smaller working set
                            Malt.stop(wrkr)
                        end
                    else
                        # One of Malt.TerminatedWorkerException, Malt.RemoteException, or ErrorException
                        @assert result isa Exception
                        put!(printer_channel, (:crashed, test, worker_id(wrkr)))
                        if args.quickfail !== nothing
                            stop_work()
                            return
                        end

                        # the worker encountered some serious failure, recycle it
                        Malt.stop(wrkr)
                    end

                    # get rid of the custom worker
                    if wrkr != p
                        Malt.stop(wrkr)
                    end

                    @lock running_tests begin
                        delete!(running_tests[], test)
                    end
                catch ex
                    isa(ex, InterruptException) || rethrow()
                finally
                    if acquired
                        # stop the worker if no more tests will need one from the pool
                        if tests_to_start[] == 0 && p !== nothing && Malt.isrunning(p)
                            Malt.stop(p)
                            p = nothing
                        end
                        put!(worker_pool, p)
                        Base.release(sem)
                    end
                end
            end)
        end
    catch err
        if !(err isa InterruptException)
            println(io_ctx.stderr, "\nCaught an error, stopping...")
        end
    finally
        stop_work()
    end

    #
    # finalization
    #

    # wait for the printer to finish so that all results have been printed
    close(printer_channel)
    wait(printer_task)

    # wait for worker tasks to catch unhandled exceptions
    for task in worker_tasks
        try
            wait(task)
        catch err
            # unwrap TaskFailedException
            while isa(err, TaskFailedException)
                err = current_exceptions(err.task)[1].exception
            end

            isa(err, InterruptException) || rethrow()
        end
    end

    # clean up remaining workers in the pool
    close(worker_pool)
    for p in worker_pool
        if p !== nothing && Malt.isrunning(p)
            Malt.stop(p)
        end
    end

    # print the output generated by each testset
    # (`@sync` above joined all writers, so `results` is quiescent from here on)
    for (testname, result, output, _start, _stop) in results.value
        if !isempty(output)
            print(io_ctx.stdout, "\nOutput generated during execution of '")
            if result isa Exception || anynonpass(result[])
                printstyled(io_ctx.stdout, testname; color=:red)
            else
                printstyled(io_ctx.stdout, testname; color=:normal)
            end
            println(io_ctx.stdout, "':")
            lines = collect(eachline(IOBuffer(output)))

            for (i,line) in enumerate(lines)
                prefix = if length(lines) == 1
                    "["
                elseif i == 1
                    "┌"
                elseif i == length(lines)
                    "└"
                else
                    "│"
                end
                println(io_ctx.stdout, prefix, " ", line)
            end
        end
    end

    # process test results and convert into a testset
    function create_testset(name; start=nothing, stop=nothing, kwargs...)
        if start === nothing
            testset = Test.DefaultTestSet(name; kwargs...)
        elseif VERSION >= v"1.13.0-DEV.1297"
            testset = Test.DefaultTestSet(name; time_start=start, kwargs...)
        elseif VERSION < v"1.13.0-DEV.1037"
            testset = Test.DefaultTestSet(name; kwargs...)
            testset.time_start = start
        else
            # no way to set time_start retroactively
            testset = Test.DefaultTestSet(name; kwargs...)
        end

        if stop !== nothing
            if VERSION < v"1.13.0-DEV.1037"
                testset.time_end = stop
            elseif VERSION >= v"1.13.0-DEV.1297"
                @atomic testset.time_end = stop
            else
                # if we can't set the start time, also don't set a stop one
                # to avoid negative timings
            end
        end

        return testset
    end
    t1 = time()
    o_ts = create_testset("Overall"; start=t0, stop=t1, verbose=!isnothing(args.verbose))
    function collect_results()
        with_testset(o_ts) do
            completed_tests = Set{String}()
            for (testname, result, _output, start, stop) in results.value
                push!(completed_tests, testname)

                if result isa AbstractTestRecord
                    testset = result[]::DefaultTestSet
                    historical_durations[testname] = stop - start
                else
                    # If this test raised an exception that means the test runner itself had some problem,
                    # so we may have hit a segfault, deserialization errors or something similar.
                    # Record this testset as Errored.
                    # One of Malt.TerminatedWorkerException, Malt.RemoteException, or ErrorException
                    @assert result isa Exception
                    testset = create_testset(testname; start, stop)
                    Test.record(testset, Test.Error(:nontest_error, testname, nothing, Base.ExceptionStack(NamedTuple[(;exception = result, backtrace = [])]), LineNumberNode(1)))
                end

                with_testset(testset) do
                    Test.record(o_ts, testset)
                end
            end

            # mark remaining or running tests as interrupted
            for test in tests
                (test in completed_tests) && continue
                testset = create_testset(test)
                Test.record(testset, Test.Error(:test_interrupted, test, nothing, Base.ExceptionStack(NamedTuple[(;exception = "skipped", backtrace = [])]), LineNumberNode(1)))
                with_testset(testset) do
                    Test.record(o_ts, testset)
                end
            end
        end
    end
    @static if VERSION >= v"1.13.0-DEV.1044"
        @with Test.TESTSET_PRINT_ENABLE => false begin
            collect_results()
        end
    else
        old_print_setting = Test.TESTSET_PRINT_ENABLE[]
        Test.TESTSET_PRINT_ENABLE[] = false
        try
            collect_results()
        finally
            Test.TESTSET_PRINT_ENABLE[] = old_print_setting
        end
    end
    save_test_history(mod, historical_durations)

    # display the results
    println(io_ctx.stdout)
    if VERSION >= v"1.13.0-DEV.1033"
        Test.print_test_results(io_ctx.stdout, o_ts, 1)
    else
        c = IOCapture.capture(; io_ctx.color) do
            Test.print_test_results(o_ts, 1)
        end
        print(io_ctx.stdout, c.output)
    end
    if !anynonpass(o_ts)
        printstyled(io_ctx.stdout, "    SUCCESS\n"; bold=true, color=:green)
    else
        printstyled(io_ctx.stderr, "    FAILURE\n\n"; bold=true, color=:red)
        if VERSION >= v"1.13.0-DEV.1033"
            Test.print_test_errors(io_ctx.stdout, o_ts)
        else
            c = IOCapture.capture(; io_ctx.color) do
                Test.print_test_errors(o_ts)
            end
            print(io_ctx.stdout, c.output)
        end
        throw(Test.FallbackTestSetException("Test run finished with errors"))
    end

    return
end
runtests(mod::Module, ARGS::Array{String}; kwargs...) = runtests(mod, parse_args(ARGS); kwargs...)

end
