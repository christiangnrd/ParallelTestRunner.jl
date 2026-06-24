module Utils
    using Test
    using Scratch
    using Serialization

    #Always set the max rss so that if tests add large global variables (which they do) we don't make the GC's life too hard
    function get_max_worker_rss()
        mb = if haskey(ENV, "JULIA_TEST_MAXRSS_MB")
            parse(Int, ENV["JULIA_TEST_MAXRSS_MB"])
        elseif Sys.WORD_SIZE == 64
            Sys.total_memory() > 8*Int64(2)^30 ? 3800 : 3000
        else
            # Assume that we only have 3.5GB available to a single process, and that a single
            # test can take up to 2GB of RSS.  This means that we should instruct the test
            # framework to restart any worker that comes into a test set with 1.5GB of RSS.
            1536
        end
        return mb * 2^20
    end

    """
        WorkerTestSet

    A test set wrapper used internally by worker processes.
    `Base.DefaultTestSet` detects when it is the top-most and throws
    a `TestSetException` containing very little information. By inserting this
    wrapper as the top-most test set, we can capture the full results.
    """
    mutable struct WorkerTestSet <: Test.AbstractTestSet
        const name::String
        wrapped_ts::Test.DefaultTestSet
        function WorkerTestSet(name::AbstractString)
            new(name)
        end
    end

    function Test.record(ts::WorkerTestSet, res)
        @assert res isa Test.DefaultTestSet
        @assert !isdefined(ts, :wrapped_ts)
        ts.wrapped_ts = res
        return nothing
    end

    function Test.finish(ts::WorkerTestSet)
        # This testset is just a placeholder so it must be the top-most
        @assert Test.get_testset_depth() == 0
        @assert isdefined(ts, :wrapped_ts)
        # Return the wrapped_ts so that we don't need to handle WorkerTestSet anywhere else
        return ts.wrapped_ts
    end

    # This is an internal function, not to be used by end users.  The keyword
    # arguments are only for testing purposes.
    """
        default_njobs()

    Determine default number of parallel jobs.
    """
    function default_njobs(; cpu_threads = Sys.CPU_THREADS, free_memory = available_memory())
        jobs = cpu_threads
        memory_jobs = Int64(free_memory) ÷ (2 * Int64(2)^30)
        return max(1, min(jobs, memory_jobs))
    end

    # Historical test duration database
    function get_history_file(mod::Module)
        scratch_dir = @get_scratch!("durations")
        return joinpath(scratch_dir, "v$(VERSION.major).$(VERSION.minor)", "$(nameof(mod)).jls")
    end
    function load_test_history(mod::Module)
        history_file = get_history_file(mod)
        if isfile(history_file)
            try
                return deserialize(history_file)
            catch e
                @warn "Failed to load test history from $history_file" exception=e
                return Dict{String, Float64}()
            end
        else
            return Dict{String, Float64}()
        end
    end
    function save_test_history(mod::Module, history::Dict{String, Float64})
        history_file = get_history_file(mod)
        try
            mkpath(dirname(history_file))
            serialize(history_file, history)
        catch e
            @warn "Failed to save test history to $history_file" exception=e
        end
    end

    # ── Compatibility wrappers ────────────────────────────────────────────────────────
    function anynonpass(ts::Test.AbstractTestSet)
        @static if VERSION >= v"1.13.0-DEV.1037"
            return Test.anynonpass(ts)
        else
            Test.get_test_counts(ts)
            return ts.anynonpass
        end
    end

    function with_testset(f, testset)
        @static if VERSION >= v"1.13.0-DEV.1044"
            Test.@with_testset testset f()
        else
            Test.push_testset(testset)
            try
                f()
            finally
                Test.pop_testset()
            end
        end
        return nothing
    end

    # Thin compatibility shim for using `Lockable` also in Julia v1.10
    if VERSION >= v"1.11.0-DEV.1568"
        const Lockable = Base.Lockable
    else
        # Adapted from <https://github.com/JuliaLang/julia/pull/52898>.
        struct Lockable{T, L <: Base.AbstractLock}
            value::T
            lock::L
        end

        Lockable(value) = Lockable(value, ReentrantLock())
        Base.getindex(l::Lockable) = (Base.assert_havelock(l.lock); l.value)

        Base.lock(l::Lockable) = Base.lock(l.lock)
        Base.trylock(l::Lockable) = Base.trylock(l.lock)
        Base.unlock(l::Lockable) = Base.unlock(l.lock)
    end

    # Use a different `available_memory` function for macOS
    @static if Sys.isapple()
        mutable struct VmStatistics64
       	free_count::UInt32
       	active_count::UInt32
       	inactive_count::UInt32
       	wire_count::UInt32
       	zero_fill_count::UInt64
       	reactivations::UInt64
       	pageins::UInt64
       	pageouts::UInt64
       	faults::UInt64
       	cow_faults::UInt64
       	lookups::UInt64
       	hits::UInt64
       	purges::UInt64
       	purgeable_count::UInt32

       	speculative_count::UInt32

       	decompressions::UInt64
       	compressions::UInt64
       	swapins::UInt64
       	swapouts::UInt64
       	compressor_page_count::UInt32
       	throttled_count::UInt32
       	external_page_count::UInt32
       	internal_page_count::UInt32
       	total_uncompressed_pages_in_compressor::UInt64

       	VmStatistics64() = new(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        end


        function available_memory()
       	vms = Ref{VmStatistics64}(VmStatistics64())
       	mach_host_self = @ccall mach_host_self()::UInt32
       	count = UInt32(sizeof(VmStatistics64) ÷ sizeof(Int32))
       	ref_count = Ref(count)
       	@ccall host_statistics64(mach_host_self::UInt32, 4::Int64, pointer_from_objref(vms[])::Ptr{Int64}, ref_count::Ref{UInt32})::Int64

       	page_size = Int(@ccall sysconf(29::UInt32)::UInt32)

       	return (Int(vms[].free_count) + Int(vms[].inactive_count) + Int(vms[].purgeable_count) + Int(vms[].compressor_page_count)) * page_size
        end
    else
        available_memory() = Sys.free_memory()
    end


end
