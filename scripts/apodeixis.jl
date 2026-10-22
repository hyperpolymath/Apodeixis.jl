#!/usr/bin/env julia
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

using Apodeixis

function usage(io=stdout)
    println(io, "Usage: julia --project=. scripts/apodeixis.jl audit [--mutation-score PERCENT] FILE.jl")
    println(io, "       julia --project=. scripts/apodeixis.jl --help")
    println(io, "Audits source policy only; POLICY CLEAN is not a verification proof.")
end

function main(args)
    if isempty(args) || args == ["--help"] || args == ["-h"]
        usage()
        return isempty(args) ? 2 : 0
    end
    args[1] == "audit" || (usage(stderr); return 2)

    score = nothing
    file = nothing
    i = 2
    while i <= length(args)
        arg = args[i]
        if arg == "--mutation-score"
            i == length(args) && (println(stderr, "missing percentage after --mutation-score"); return 2)
            i += 1
            score = tryparse(Float64, args[i])
            score === nothing && (println(stderr, "invalid mutation score: ", args[i]); return 2)
        elseif startswith(arg, "-")
            println(stderr, "unknown option: ", arg)
            usage(stderr)
            return 2
        elseif file === nothing
            file = arg
        else
            println(stderr, "expected exactly one source file")
            usage(stderr)
            return 2
        end
        i += 1
    end

    file === nothing && (usage(stderr); return 2)
    isfile(file) || (println(stderr, "file not found: ", file); return 2)
    report = try
        audit_file(file; mutation_score=score)
    catch err
        println(stderr, "Apodeixis could not read ", file, ": ", sprint(showerror, err))
        return 2
    end

    if isempty(report.findings)
        println("POLICY CLEAN (NOT VERIFIED): ", report.filename)
        return 0
    end
    println("REJECTED: ", report.filename)
    for finding in report.findings
        println("  ", finding.code, " [line ", finding.line, "]: ", finding.message)
    end
    return 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
