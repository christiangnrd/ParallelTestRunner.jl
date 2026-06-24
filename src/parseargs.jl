
"""
    ParsedArgs

Struct representing parsed command line arguments, to be passed to [`runtests`](@ref).
`ParsedArgs` objects are typically obtained by using [`parse_args`](@ref).

Fields are

* `jobs::Union{Some{Int}, Nothing}`: the number of jobs
* `verbose::Union{Some{Nothing}, Nothing}`: whether verbose printing was enabled
* `quickfail::Union{Some{Nothing}, Nothing}`: whether quick fail was enabled
* `list::Union{Some{Nothing}, Nothing}`: whether tests should be listed
* `custom::Dict{String,Any}`: a dictionary of custom arguments
* `positionals::Vector{String}`: the list of positional arguments passed on the command line, i.e. the explicit list of test files (to be matches with `startswith`)
"""
struct ParsedArgs
    jobs::Union{Some{Int}, Nothing}
    verbose::Union{Some{Nothing}, Nothing}
    quickfail::Union{Some{Nothing}, Nothing}
    list::Union{Some{Nothing}, Nothing}

    custom::Dict{String,Any}

    positionals::Vector{String}
end

# parse some command-line arguments
function extract_flag!(args, flag; typ = Nothing)
    for f in args
        if startswith(f, flag)
            # Check if it's just `--flag` or if it's `--flag=foo`
            val = if f == flag
                nothing
            else
                parts = split(f, '=')
                if typ === Nothing || typ <: AbstractString
                    parts[2]
                else
                    parse(typ, parts[2])
                end
            end

            # Drop this value from our args
            filter!(x -> x != f, args)
            return Some(val)
        end
    end
    return nothing
end

"""
    parse_args(args; [custom::Array{String}]) -> ParsedArgs

Parse command-line arguments for `runtests`. Typically invoked by passing `Base.ARGS`.

Fields of this structure represent command-line options, containing `nothing` when the
option was not specified, or `Some(optional_value=nothing)` when it was.

Custom arguments can be specified via the `custom` keyword argument, which should be
an array of strings representing custom flag names (without the `--` prefix). Presence
of these flags will be recorded in the `custom` field of the returned [`ParsedArgs`](@ref) object.
"""
function parse_args(args; custom::Array{String} = String[])
    args = copy(args)

    help = extract_flag!(args, "--help")
    if help !== nothing
        usage =
            """
            Usage: runtests.jl [--help] [--list] [--jobs=N] [TESTS...]

               --help             Show this text.
               --list             List all available tests.
               --verbose          Print more information during testing.
               --quickfail        Fail the entire run as soon as a single test errored.
               --jobs=N           Launch `N` processes to perform tests."""

        if !isempty(custom)
            usage *= "\n\nCustom arguments:"
            for flag in custom
                usage *= "\n   --$flag"
            end
        end
        usage *= "\n\nRemaining arguments filter the tests that will be executed."
        println(usage)
        exit(0)
    end

    jobs = extract_flag!(args, "--jobs"; typ = Int)
    verbose = extract_flag!(args, "--verbose")
    quickfail = extract_flag!(args, "--quickfail")
    list = extract_flag!(args, "--list")

    custom_args = Dict{String,Any}()
    for flag in custom
        custom_args[flag] = extract_flag!(args, "--$flag")
    end

    ## no options should remain
    optlike_args = filter(startswith("-"), args)
    if !isempty(optlike_args)
        error("Unknown test options `$(join(optlike_args, " "))` (try `--help` for usage instructions)")
    end

    return ParsedArgs(jobs, verbose, quickfail, list, custom_args, args)
end

"""
    filter_tests!(testsuite, args::ParsedArgs) -> Bool

Filter tests in `testsuite` based on command-line arguments in `args`.

Returns `true` if additional filtering may be done by the caller, `false` otherwise.

When `--list` is requested, the full `testsuite` is preserved and `false` is
returned so that callers skip any conditional filtering of their own: listing
should show every available test, not just the ones that would run by default.
"""
function filter_tests!(testsuite, args::ParsedArgs)
    # when only listing tests, keep the full catalog and let the caller skip its
    # own filtering, so that every available test is shown
    args.list !== nothing && return false

    # the user did not request specific tests, so let the caller do its own filtering
    isempty(args.positionals) && return true

    # only select tests matching positional arguments
    tests = collect(keys(testsuite))
    for test in tests
        if !any(arg -> startswith(test, arg), args.positionals)
            delete!(testsuite, test)
        end
    end

    # the user requested specific tests, so don't allow further filtering
    return false
end
