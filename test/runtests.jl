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
            "global mutable_state = 1",
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
