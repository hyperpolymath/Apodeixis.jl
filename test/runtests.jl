# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

using Test
using Apodeixis

codes(report) = Set(f.code for f in report.findings)

@testset "Apodeixis source-policy MVP" begin
    @testset "admitted declarations are parsed, not expanded" begin
        report = audit_source("""
            @verified function positive(x::Int)
                @pre x > 0
                @post x > 0
                @tier ExactLinear
                @cap(pure)
                x
            end
            """)
        @test report.status === :policy_clean
        @test isempty(report.findings)
        @test is_policy_clean(report)
    end

    @testset "inbounds needs both policy gates" begin
        source = """
            @verified function getfirst(A::Vector{Int})
                @inbounds A[1]
            end
            """
        missing_score = audit_source(source)
        @test :APX_INBOUNDS_OUTSIDE_VERIFIED ∉ codes(missing_score)
        @test :APX_MUTATION_GATE in codes(missing_score)
        @test !is_policy_clean(missing_score)

        passing_gate = audit_source(source; mutation_score=95)
        @test passing_gate.status === :policy_clean

        low_score = audit_source(source; mutation_score=94.99)
        @test :APX_MUTATION_GATE in codes(low_score)
        qualified_macro = audit_source("""
            @verified function getfirst(A::Vector{Int})
                Base.@inbounds A[1]
            end
            """; mutation_score=94)
        @test :APX_MUTATION_GATE in codes(qualified_macro)

        unverified = audit_source("function f(A); @inbounds A[1]; end";
                                  mutation_score=100)
        @test :APX_INBOUNDS_OUTSIDE_VERIFIED in codes(unverified)
    end

    @testset "unsafe escape hatches fail closed" begin
        for source in (
            "@eval const x = 1",
            "Base.invokelatest(identity, 1)",
            "function f(p); ccall(:f, Cvoid, (), p); end",
            "@generated function f(x); x; end",
            "@fastmath 1.0 + 2.0",
            "Base.@fastmath 1.0 + 2.0",
            "@verified function f(); global mutable_state = 1; end",
        )
            @test !is_policy_clean(audit_source(source))
        end
        @test :APX_UNMODELED_CCALL in codes(
            audit_source("function f(p); ccall(:f, Cvoid, (), p); end"))
    end

    @testset "unelaborated macros and nested verification boundaries" begin
        unmodeled = audit_source("""
            @verified function f(x)
                @mystery x
            end
            """)
        @test :APX_UNMODELED_MACRO in codes(unmodeled)

        # Parsing must never execute user macro definitions or invocations.
        no_expansion = audit_source("""
            macro explosive()
                error(\"macro was expanded\")
            end
            @verified function f(x)
                @explosive x
            end
            """)
        @test :APX_UNMODELED_MACRO in codes(no_expansion)

        nested = audit_source("""
            @verified function outer(A)
                inner(B) = (@inbounds B[1])
                inner(A)
            end
            """; mutation_score=100)
        @test :APX_INBOUNDS_OUTSIDE_VERIFIED in codes(nested)
    end

    @testset "parse errors and score validation are explicit" begin
        @test :APX_INVALID_VERIFIED_MARKER in codes(audit_source("@verified begin; 1; end"))
        @test :APX_PARSE_ERROR in codes(audit_source("function ("))
        @test_throws ArgumentError audit_source("x = 1"; mutation_score=100.1)
        @test_throws ArgumentError audit_source("x = 1"; mutation_score=-0.1)
    end
end

@testset "Audit API and policy regressions" begin
    @testset "clean input and report metadata" begin
        for source in ("", " \n\t", "# eval(:x) and @fastmath are comments",
                       "message = \"eval(:x); @inbounds A[1]\"",
                       "evaluation(x) = x; invokelatest_value = :eval")
            report = audit_source(source)
            @test report isa AuditReport
            @test report.filename == "<memory>"
            @test report.status === :policy_clean
            @test isempty(report.findings)
            @test is_policy_clean(report)
        end
        source = SubString("x = 1", 1, 5)
        filename = SubString("α source.jl", 1)
        report = audit_source(source; filename=filename)
        @test report.filename == String(filename)
        @test is_policy_clean(report)
    end

    @testset "each unsafe call and macro, including qualified names" begin
        for call in ("eval(:x)", "invokelatest(identity, 1)",
                     "unsafe_load(p)", "unsafe_store!(p, 1)",
                     "ccall(:f, Cvoid, ())")
            expected = startswith(call, "ccall") ? :APX_UNMODELED_CCALL : :APX_DYNAMIC_ESCAPE
            for prefix in ("", "Base."), verified in (false, true)
                expression = prefix * call
                source = verified ? "@verified f(p) = ($expression)" : expression
                @testset "$source" begin
                    report = audit_source(source)
                    @test report.status === :rejected
                    @test !is_policy_clean(report)
                    @test codes(report) == Set([expected])
                    @test all(f -> f isa Finding && f.line >= 1 && !isempty(f.message),
                              report.findings)
                end
            end
        end
        for invocation in ("@eval x = 1", "@generated function f(x); x; end",
                           "@fastmath 1.0 + 2.0")
            for prefix in ("", "Base.")
                expression = prefix * invocation
                for source in (expression, "@verified function f(); $expression; end")
                    @test codes(audit_source(source)) == Set([:APX_FORBIDDEN_MACRO])
                end
            end
        end
    end

    @testset "contract syntax and annotation boundaries" begin
        for marker in ("@pre x > 0", "@post x > 0", "@invariant x > 0",
                       "@cap(pure)", "@tier ExactLinear", "@noalloc x", "@echo x")
            for prefix in ("", "Contracts.")
                @test is_policy_clean(audit_source(
                    "@verified function f(x); $(prefix)$(marker); x; end"))
            end
        end
        for source in ("@verified f(A) = (@inbounds A[1])",
                       "Contracts.@verified function f(A); @inbounds A[1]; end")
            @test is_policy_clean(audit_source(source; mutation_score=95))
        end
        for source in ("@verified", "@verified x", "@verified f(x)",
                       "@verified 1 2", "@verified begin; f(x) = x; end")
            @test codes(audit_source(source)) == Set([:APX_INVALID_VERIFIED_MARKER])
        end
        # An invalid marker must still audit its payload without granting scope.
        invalid = audit_source("@verified begin; @inbounds A[1]; eval(:x); end")
        @test codes(invalid) == Set([:APX_INVALID_VERIFIED_MARKER,
                                    :APX_INBOUNDS_OUTSIDE_VERIFIED,
                                    :APX_MUTATION_GATE, :APX_DYNAMIC_ESCAPE])

        for definition in ("inner(B) = (@inbounds B[1])",
                           "function inner(B); @inbounds B[1]; end")
            source = "@verified function outer(A); $definition; inner(A); end"
            @test codes(audit_source(source; mutation_score=100)) ==
                  Set([:APX_INBOUNDS_OUTSIDE_VERIFIED])
            # A nested method can establish its own independent boundary.
            annotated = "@verified function outer(A); @verified $definition; inner(A); end"
            @test is_policy_clean(audit_source(annotated; mutation_score=100))
        end
        siblings = "@verified f(A) = (@inbounds A[1])\ng(A) = (@inbounds A[1])"
        @test codes(audit_source(siblings; mutation_score=100)) ==
              Set([:APX_INBOUNDS_OUTSIDE_VERIFIED])

        # The MVP rejects global declarations only within the annotated body.
        @test is_policy_clean(audit_source("global mutable_state = 1"))
        @test is_policy_clean(audit_source("function f(); global mutable_state = 1; end"))
        @test codes(audit_source("@verified f() = (global mutable_state = 1)")) ==
              Set([:APX_GLOBAL_MUTATION])
        @test is_policy_clean(audit_source("@mystery 1"))
        @test codes(audit_source("@verified f(x) = (Other.@mystery x)")) ==
              Set([:APX_UNMODELED_MACRO])
    end

    @testset "mutation gate endpoints and non-finite inputs" begin
        source = "@verified f(A) = (@inbounds A[1])"
        for score in (nothing, 0, 94, prevfloat(95.0))
            @test codes(audit_source(source; mutation_score=score)) == Set([:APX_MUTATION_GATE])
        end
        for score in (95, 95.0, nextfloat(95.0), 95//1, big"95", 100)
            @test is_policy_clean(audit_source(source; mutation_score=score))
        end
        for score in (0, 100)
            @test is_policy_clean(audit_source("x = 1"; mutation_score=score))
        end
        for score in (-eps(), nextfloat(100.0), NaN, Inf, -Inf)
            @test_throws ArgumentError audit_source("x = 1"; mutation_score=score)
        end
        # The score cannot compensate for a missing @verified boundary.
        for (score, expected) in ((nothing, Set([:APX_INBOUNDS_OUTSIDE_VERIFIED,
                                               :APX_MUTATION_GATE])),
                                  (95, Set([:APX_INBOUNDS_OUTSIDE_VERIFIED])))
            @test codes(audit_source("@inbounds A[1]"; mutation_score=score)) == expected
        end
    end

    @testset "diagnostic locations, deduplication, and parse failures" begin
        source = "\n@eval x = 1\nBase.eval(:x)\n@fastmath 1.0 + 2.0\n"
        report = audit_source(source; filename="diagnostics.jl")
        @test report.filename == "diagnostics.jl"
        @test [(f.code, f.line) for f in report.findings] ==
              [(:APX_FORBIDDEN_MACRO, 2), (:APX_DYNAMIC_ESCAPE, 3), (:APX_FORBIDDEN_MACRO, 4)]
        repeated = audit_source(source)
        @test [(f.code, f.line, f.message) for f in report.findings] ==
              [(f.code, f.line, f.message) for f in repeated.findings]
        duplicates = audit_source("eval(:x); eval(:y)\neval(:z)")
        @test [(f.code, f.line) for f in duplicates.findings] ==
              [(:APX_DYNAMIC_ESCAPE, 1), (:APX_DYNAMIC_ESCAPE, 2)]
        distinct = audit_source("eval(:x); unsafe_load(p)")
        @test length(distinct.findings) == 2
        @test length(Set(f.message for f in distinct.findings)) == 2
        for source in ("function (", "@verified function f(x)\n x", "x = [1,", "\"unterminated")
            report = audit_source(source; filename="broken.jl")
            @test report.status === :rejected
            @test !is_policy_clean(report)
            @test codes(report) == Set([:APX_PARSE_ERROR])
            @test report.filename == "broken.jl"
            @test all(f -> f.line >= 1 && !isempty(f.message), report.findings)
        end
    end

    @testset "source, macro definitions, and files are never executed" begin
        mktempdir() do dir
            marker = joinpath(dir, "executed")
            effect = "write($(repr(marker)), \"executed\")"
            for source in (effect, "macro touch_marker(); $effect; :(nothing); end\n@touch_marker()")
                @test is_policy_clean(audit_source(source))
                @test !ispath(marker)
            end
            path = joinpath(dir, "source α with spaces.jl")
            source = "@verified f(A) = (@inbounds A[1])\n$effect"
            write(path, source)
            report = audit_file(path; mutation_score=95)
            @test report.filename == path
            @test is_policy_clean(report)
            @test codes(audit_file(path)) == Set([:APX_MUTATION_GATE])
            @test read(path, String) == source
            @test !ispath(marker)
            write(path, "eval(:x)")
            @test codes(audit_file(path)) == Set([:APX_DYNAMIC_ESCAPE])
            write(path, "function (")
            @test codes(audit_file(path)) == Set([:APX_PARSE_ERROR])
            @test_throws ArgumentError audit_file(path; mutation_score=NaN)
            @test_throws SystemError audit_file(joinpath(dir, "missing.jl"))
        end
    end
end

# Including the CLI exercises main directly and must not exit the test runner.
module CLIUnderTest
include(joinpath(@__DIR__, "..", "scripts", "apodeixis.jl"))

function invoke(args)
    mktemp() do _, output
        mktemp() do _, errors
            status = redirect_stdout(output) do
                redirect_stderr(errors) do
                    main(args)
                end
            end
            seekstart(output)
            seekstart(errors)
            return (status=status, out=read(output, String), err=read(errors, String))
        end
    end
end
end

@testset "CLI argument handling and audit output" begin
    for flag in ("--help", "-h")
        result = CLIUnderTest.invoke([flag])
        @test result.status == 0
        @test occursin("Usage:", result.out)
        @test occursin("not a verification proof", result.out)
        @test isempty(result.err)
    end
    result = CLIUnderTest.invoke(String[])
    @test result.status == 2
    @test occursin("Usage:", result.out)
    @test isempty(result.err)

    mktempdir() do dir
        path = joinpath(dir, "source with spaces.jl")
        write(path, "identity(1)\n")
        result = CLIUnderTest.invoke(["audit", path])
        @test result == (status=0, out="POLICY CLEAN (NOT VERIFIED): $path\n", err="")

        for (args, diagnostic) in ((["verify", path], "Usage:"),
                                   (["audit"], "Usage:"),
                                   (["audit", "--mutation-score"], "missing percentage"),
                                   (["audit", "--mutation-score", "oops", path], "invalid mutation score"),
                                   (["audit", "--unknown", path], "unknown option"),
                                   (["audit", path, "second.jl"], "expected exactly one source file"),
                                   (["audit", joinpath(dir, "missing.jl")], "file not found"),
                                   (["audit", dir], "file not found"))
            @testset "$args" begin
                result = CLIUnderTest.invoke(args)
                @test result.status == 2
                @test isempty(result.out)
                @test occursin(diagnostic, result.err)
            end
        end
        for score in ("-0.1", "100.1", "NaN", "Inf", "-Inf")
            result = CLIUnderTest.invoke(["audit", "--mutation-score", score, path])
            @test result.status == 2
            @test isempty(result.out)
            @test occursin("mutation_score must be a percentage", result.err)
        end

        write(path, "\nBase.eval(:x)\n@fastmath 1.0 + 2.0\n")
        result = CLIUnderTest.invoke(["audit", path])
        @test result.status == 1
        @test startswith(result.out, "REJECTED: $path\n")
        @test occursin("APX_DYNAMIC_ESCAPE [line 2]", result.out)
        @test occursin("APX_FORBIDDEN_MACRO [line 3]", result.out)
        @test !occursin("POLICY CLEAN", result.out)
        @test isempty(result.err)

        write(path, "@verified f(A) = (@inbounds A[1])")
        for args in (["audit", "--mutation-score", "95", path],
                     ["audit", path, "--mutation-score", "97.5"])
            result = CLIUnderTest.invoke(args)
            @test result.status == 0
            @test startswith(result.out, "POLICY CLEAN (NOT VERIFIED):")
            @test isempty(result.err)
        end
        for args in (["audit", path], ["audit", "--mutation-score", "94.99", path])
            result = CLIUnderTest.invoke(args)
            @test result.status == 1
            @test occursin("APX_MUTATION_GATE", result.out)
            @test isempty(result.err)
        end
        write(path, "function (")
        result = CLIUnderTest.invoke(["audit", path])
        @test result.status == 1
        @test occursin("APX_PARSE_ERROR", result.out)
        @test isempty(result.err)

        # Check the executable guard propagates main's success, rejection,
        # and usage statuses to the operating system.
        script = joinpath(@__DIR__, "..", "scripts", "apodeixis.jl")
        project = dirname(@__DIR__)
        for (args, status, output) in ((["--help"], 0, "Usage:"),
                                       (["audit", path], 1, "REJECTED:"),
                                       (String[], 2, "Usage:"))
            command = `$(Base.julia_cmd()) --startup-file=no --project=$project $script $args`
            io = IOBuffer()
            process = run(pipeline(ignorestatus(command); stdout=io, stderr=io))
            @test process.exitcode == status
            @test occursin(output, String(take!(io)))
        end
    end
end
