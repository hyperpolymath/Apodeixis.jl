#!/usr/bin/env julia
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

using Apodeixis

function usage(io=stdout)
    println(io, "Usage: julia --project=. scripts/apodeixis.jl audit [--mutation-score PERCENT] FILE.jl")
    println(io, "       julia --project=. scripts/apodeixis.jl audit-package [--mutation-score PERCENT] ROOT.jl")
    println(io, "       julia --project=. scripts/apodeixis.jl --help")
    println(io, "Audits source policy only; POLICY CLEAN is not a verification proof.")
end

function run_package(file, score)
    report = try
        audit_package(file; mutation_score=score)
    catch err
        println(stderr, "Apodeixis could not read ", file, ": ", sprint(showerror, err))
        return 2
    end
    for r in report.reports
        if isempty(r.findings)
            println("POLICY CLEAN (NOT VERIFIED): ", r.filename)
        else
            println("REJECTED: ", r.filename)
            for f in r.findings
                println("  ", f.code, " [line ", f.line, "]: ", f.message)
            end
        end
    end
    if !isempty(report.findings)
        println("PACKAGE FINDINGS:")
        for f in report.findings
            println("  ", f.code, " [line ", f.line, "]: ", f.message)
        end
    end
    if !isempty(report.unreached)
        println("UNREACHED (not audited, no include reaches them):")
        for u in report.unreached
            println("  ", u)
        end
    end
    nfiles = length(report.reports)
    nbad = count(r -> !isempty(r.findings), report.reports)
    println(is_policy_clean(report) ? "PACKAGE POLICY CLEAN (NOT VERIFIED): " : "PACKAGE REJECTED: ",
            nfiles, " file(s) reached, ", nbad, " with findings, ",
            length(report.findings), " package finding(s), ",
            length(report.unreached), " unreached")
    return is_policy_clean(report) ? 0 : 1
end

function main(args)
    if isempty(args) || args == ["--help"] || args == ["-h"]
        usage()
        return isempty(args) ? 2 : 0
    end
    args[1] in ("audit", "audit-package") || (usage(stderr); return 2)
    package_mode = args[1] == "audit-package"

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
    package_mode && return run_package(file, score)
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
