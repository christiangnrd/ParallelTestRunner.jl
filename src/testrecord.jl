
"""
    AbstractTestRecord

Abstract supertype for per-test result records. [`TestRecord`](@ref) is the
default concrete subtype, carrying the captured test set and baseline timing /
memory statistics. Custom subtypes can attach extra per-test data (e.g. GPU
statistics) by carrying a `base::TestRecord` field and dispatching
[`execute`](@ref) on the new type. See the `RecordType` argument of
[`runtests`](@ref) for how to plug a custom record type into a run.
"""
abstract type AbstractTestRecord end

"""
    TestRecord <: AbstractTestRecord

Default per-test record. Holds the captured `DefaultTestSet` alongside the
baseline timing and memory statistics that [`runtests`](@ref) prints and
persists. Custom [`AbstractTestRecord`](@ref) subtypes wrap a `TestRecord` in a
`base` field; [`parent`](@ref) returns that baseline so the default `print_*`
methods work unchanged.
"""
struct TestRecord <: AbstractTestRecord
    value::DefaultTestSet

    # stats
    time::Float64
    bytes::UInt64
    gctime::Float64
    compile_time::Float64
    rss::UInt64
    total_time::Float64
end

"""
    parent(rec::AbstractTestRecord) -> TestRecord

Return the [`TestRecord`](@ref) baseline that a custom record type wraps. By
default, subtypes of `AbstractTestRecord` are expected to carry a
`base::TestRecord` field; override `parent` for a different layout. The default
`print_*` methods read baseline fields through `parent`, so wrapped types
inherit the standard output unchanged.
"""
Base.parent(rec::AbstractTestRecord) = rec.base
Base.parent(rec::TestRecord) = rec

function memory_usage(rec::AbstractTestRecord)
    return parent(rec).rss
end

function Base.getindex(rec::AbstractTestRecord)
    return parent(rec).value
end


#
# overridable I/O context for pretty-printing
#

struct TestIOContext
    stdout::IO
    stderr::IO
    color::Bool
    verbose::Bool
    lock::ReentrantLock
    name_align::Int
    elapsed_align::Int
    compile_align::Int
    gc_align::Int
    percent_align::Int
    alloc_align::Int
    rss_align::Int
end

function test_IOContext(::Type{<:AbstractTestRecord}, stdout::IO, stderr::IO, lock::ReentrantLock, name_align::Int, verbose::Bool)
    elapsed_align = textwidth("time (s)")
    compile_align = textwidth("Compile")
    gc_align = textwidth("GC (s)")
    percent_align = textwidth("GC %")
    alloc_align = textwidth("Alloc (MB)")
    rss_align = textwidth("RSS (MB)")

    color = get(stdout, :color, false)

    return TestIOContext(
        stdout, stderr, color, verbose, lock, name_align, elapsed_align, compile_align, gc_align, percent_align,
        alloc_align, rss_align
    )
end

function print_header(::Type{<:AbstractTestRecord}, ctx::TestIOContext, testgroupheader, workerheader)
    lock(ctx.lock)
    try
        # header top
        printstyled(ctx.stdout, " "^(ctx.name_align + textwidth(testgroupheader) - 3), " │ ", color = :white)
        printstyled(ctx.stdout, "  Test   │", color = :white)
        ctx.verbose && printstyled(ctx.stdout, "   Init   │", color = :white)
        VERSION >= v"1.11" && ctx.verbose && printstyled(ctx.stdout, " Compile │", color = :white)
        printstyled(ctx.stdout, " ──────────────── CPU ──────────────── │\n", color = :white)

        # header bottom
        printstyled(ctx.stdout, testgroupheader, color = :white)
        printstyled(ctx.stdout, lpad(workerheader, ctx.name_align - textwidth(testgroupheader) + 1), " │ ", color = :white)
        printstyled(ctx.stdout, "time (s) │", color = :white)
        ctx.verbose && printstyled(ctx.stdout, " time (s) │", color = :white)
        VERSION >= v"1.11" && ctx.verbose && printstyled(ctx.stdout, "   (%)   │", color = :white)
        printstyled(ctx.stdout, " GC (s) │ GC % │ Alloc (MB) │ RSS (MB) │\n", color = :white)
        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_started(::Type{<:AbstractTestRecord}, wrkr, test, ctx::TestIOContext)
    lock(ctx.lock)
    try
        printstyled(ctx.stdout, test, lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " "), " │", color = :white)
        printstyled(
            ctx.stdout,
            " "^ctx.elapsed_align, "started at $(now())\n", color = :light_black
        )
        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_finished(record::AbstractTestRecord, wrkr, test, ctx::TestIOContext)
    base = parent(record)
    lock(ctx.lock)
    try
        printstyled(ctx.stdout, test, color = :white)
        printstyled(ctx.stdout, lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " "), " │ ", color = :white)

        time_str = @sprintf("%7.2f", base.time)
        printstyled(ctx.stdout, lpad(time_str, ctx.elapsed_align, " "), " │ ", color = :white)

        if ctx.verbose
            # pre-testset time
            init_time_str = @sprintf("%7.2f", base.total_time - base.time)
            printstyled(ctx.stdout, lpad(init_time_str, ctx.elapsed_align, " "), " │ ", color = :white)

            # compilation time
            if VERSION >= v"1.11"
                init_time_str = @sprintf("%7.2f", Float64(100*base.compile_time/base.time))
                printstyled(ctx.stdout, lpad(init_time_str, ctx.compile_align, " "), " │ ", color = :white)
            end
        end

        gc_str = @sprintf("%5.2f", base.gctime)
        printstyled(ctx.stdout, lpad(gc_str, ctx.gc_align, " "), " │ ", color = :white)
        percent_str = @sprintf("%4.1f", 100 * base.gctime / base.time)
        printstyled(ctx.stdout, lpad(percent_str, ctx.percent_align, " "), " │ ", color = :white)
        alloc_str = @sprintf("%5.2f", base.bytes / 2^20)
        printstyled(ctx.stdout, lpad(alloc_str, ctx.alloc_align, " "), " │ ", color = :white)

        rss_str = @sprintf("%5.2f", memory_usage(record) / 2^20)
        printstyled(ctx.stdout, lpad(rss_str, ctx.rss_align, " "), " │\n", color = :white)

        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_failed(record::AbstractTestRecord, wrkr, test, ctx::TestIOContext)
    base = parent(record)
    lock(ctx.lock)
    try
        printstyled(ctx.stderr, test, color = :red)
        printstyled(
            ctx.stderr,
            lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " "), " │"
            , color = :red
        )

        time_str = @sprintf("%7.2f", base.time)
        printstyled(ctx.stderr, lpad(time_str, ctx.elapsed_align + 1, " "), " │", color = :red)

        if ctx.verbose
            init_time_str = @sprintf("%7.2f", base.total_time - base.time)
            printstyled(ctx.stdout, lpad(init_time_str, ctx.elapsed_align + 1, " "), " │ ", color = :red)
        end

        failed_str = "failed at $(now())\n"
        # 11 -> 3 from " │ " 3x and 2 for each " " on either side
        fail_align = (11 + ctx.gc_align + ctx.percent_align + ctx.alloc_align + ctx.rss_align - textwidth(failed_str)) ÷ 2 + textwidth(failed_str)
        failed_str = lpad(failed_str, fail_align, " ")
        printstyled(ctx.stderr, failed_str, color = :red)

        # TODO: print other stats?

        flush(ctx.stderr)
    finally
        unlock(ctx.lock)
    end
end

function print_test_crashed(::Type{<:AbstractTestRecord}, wrkr, test, ctx::TestIOContext)
    lock(ctx.lock)
    try
        printstyled(ctx.stderr, test, color = :red)
        printstyled(
            ctx.stderr,
            lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " "), " │",
            " "^ctx.elapsed_align, " crashed at $(now())\n", color = :red
        )

        flush(ctx.stderr)
    finally
        unlock(ctx.lock)
    end
end


"""
    execute(::Type{R}, mod::Module, f, name, start_time, custom_args) where {R<:AbstractTestRecord}

Run the test expression `f` inside the sandbox module `mod` and return an
`R <: AbstractTestRecord`. This is the extension point for custom record
types: dispatch `execute(::Type{MyRecord}, …)` to collect additional per-test
statistics without re-implementing the sandbox scaffolding.

The default method for [`TestRecord`](@ref) wraps the test set in a
[`WorkerTestSet`](@ref) placeholder (so `DefaultTestSet` doesn't swallow
results at the top level), captures `@timed` stats, and records `Sys.maxrss()`.
Custom implementations commonly call `execute(TestRecord, mod, f, name,
start_time, custom_args)` to reuse that baseline and wrap the returned record
in a new record type.

Arguments:

- `mod` — the per-test sandbox module; the test expression `f` is evaluated
  into it via `@eval mod`.
- `f` — the test expression from the `testsuite` dictionary.
- `name` — the test name (used as the top-level `@testset` name).
- `start_time` — wall-clock time at which the scheduler picked up this test;
  subtract from `time()` to get total elapsed time including worker wait.
- `custom_args` — the `custom_args` value forwarded from [`runtests`](@ref)
  (arbitrary, typically a `NamedTuple`).
"""
function execute(::Type{TestRecord}, mod::Module, f, name, start_time, custom_args)
    data = @eval mod begin
        GC.gc(true)
        Random.seed!(1)

        # @testset CustomTestRecord switches the all lower-level testset to our custom testset,
        # so we need to have two layers here such that the user-defined testsets are using `DefaultTestSet`.
        # This also guarantees our invariant about `WorkerTestSet` containing a single `DefaultTestSet`.
        stats = @timed @testset WorkerTestSet "placeholder" begin
            @testset DefaultTestSet $name begin
                $f
            end
        end

        compile_time = @static VERSION >= v"1.11" ? stats.compile_time : 0.0
        (; testset=stats.value, stats.time, stats.bytes, stats.gctime, compile_time)
    end

    # process results
    rss = Sys.maxrss()
    record = TestRecord(data..., rss, time() - start_time)

    GC.gc(true)
    return record
end

function runtest(RecordType::Type{<:AbstractTestRecord}, f, name, init_code, start_time, custom_args)
    function inner()
        # generate a temporary module to execute the tests in
        mod = @eval(Main, module $(gensym(name)) end)
        @eval(mod, using ParallelTestRunner: Test, Random)
        @eval(mod, using .Test, .Random)
        # Both bindings must be imported since `@testset` can't handle fully-qualified names when VERSION < v"1.11.0-DEV.1518".
        @eval(mod, using ParallelTestRunner: WorkerTestSet)
        @eval(mod, using Test: DefaultTestSet)

        Core.eval(mod, init_code)

        return execute(RecordType, mod, f, name, start_time, custom_args)
    end

    @static if VERSION >= v"1.13.0-DEV.1044"
        @with Test.TESTSET_PRINT_ENABLE => false begin
            inner()
        end
    else
        old_print_setting = Test.TESTSET_PRINT_ENABLE[]
        Test.TESTSET_PRINT_ENABLE[] = false
        try
            inner()
        finally
            Test.TESTSET_PRINT_ENABLE[] = old_print_setting
        end
    end
end
