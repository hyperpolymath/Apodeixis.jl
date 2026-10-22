# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

"""
    Apodeixis

Initial, deliberately non-proving frontend for the Apodeixis verification
compiler. The 0.1 API parses Julia with JuliaSyntax.jl and audits a small set of
source-policy constraints. `:policy_clean` is not a verification result.
"""
module Apodeixis

using JuliaSyntax

export Finding, AuditReport, audit_source, audit_file, is_policy_clean

"""One source-policy diagnostic. `line` is 1-based when known."""
struct Finding
    code::Symbol
    line::Int
    message::String
end

"""Result of the fail-closed source-policy audit."""
struct AuditReport
    filename::String
    status::Symbol
    findings::Vector{Finding}
end

"""True when the source passed this policy audit (not a proof of correctness)."""
is_policy_clean(report::AuditReport) = report.status === :policy_clean

const _CONTRACT_MACROS = Set((
    Symbol("@verified"), Symbol("@pre"), Symbol("@post"),
    Symbol("@invariant"), Symbol("@cap"), Symbol("@tier"),
    Symbol("@noalloc"), Symbol("@echo"),
))

const _FORBIDDEN_MACROS = Set((
    Symbol("@generated"), Symbol("@eval"), Symbol("@fastmath"),
))

const _FORBIDDEN_CALLS = Set((
    :eval, :invokelatest, :ccall, :unsafe_load, :unsafe_store!,
))

function _push_once!(findings::Vector{Finding}, code::Symbol, line::Int, message::String)
    # A malformed or deeply nested syntax tree can encounter the same policy
    # violation through multiple wrappers. Keep reports deterministic and tidy.
    any(f -> f.code === code && f.line == line && f.message == message, findings) ||
        push!(findings, Finding(code, max(line, 1), message))
    return nothing
end

function _callee_symbol(x)
    x isa Symbol && return x
    if x isa GlobalRef
        return x.name
    elseif x isa Expr && x.head === :. && !isempty(x.args)
        lastarg = last(x.args)
        lastarg isa QuoteNode && return lastarg.value isa Symbol ? lastarg.value : nothing
        lastarg isa Symbol && return lastarg
    end
    return nothing
end

_is_short_function_definition(x) = x isa Expr && x.head === :(=) &&
    !isempty(x.args) && first(x.args) isa Expr && first(x.args).head === :call
_is_function_expr(x) = x isa Expr && (x.head === :function || _is_short_function_definition(x))
_macro_symbol(x) = x isa Symbol ? x : _callee_symbol(x)

"""Walk parsed Julia Expr nodes and report policy violations."""
function _walk!(x, verified::Bool, mutation_score, line::Int,
                findings::Vector{Finding}; nested_function::Bool=false)
    x isa LineNumberNode && return Int(x.line)
    x isa QuoteNode && return line
    x isa Expr || return line

    if x.head in (:error, :incomplete)
        _push_once!(findings, :APX_PARSE_ERROR, line,
                    "JuliaSyntax returned an incomplete or erroneous syntax node")
    elseif x.head === :global && verified
        _push_once!(findings, :APX_GLOBAL_MUTATION, line,
                    "global declarations are outside the verified capability subset")
    elseif x.head === :foreigncall
        _push_once!(findings, :APX_UNMODELED_CCALL, line,
                    "lowered foreign calls require a checked Idris2/Zig ABI manifest")
    elseif x.head === :call && !isempty(x.args)
        callee = _callee_symbol(first(x.args))
        if callee in _FORBIDDEN_CALLS
            code = callee === :ccall ? :APX_UNMODELED_CCALL : :APX_DYNAMIC_ESCAPE
            message = callee === :ccall ?
                "ccall is not yet verified; use a checked ABI wrapper only after the FFI phase" :
                "$(callee) is forbidden in the closed verified subset"
            _push_once!(findings, code, line, message)
        end
    end

    if x.head === :macrocall && !isempty(x.args)
        macro_name = _macro_symbol(first(x.args))
        line_arg = findfirst(arg -> arg isa LineNumberNode, x.args)
        macro_line = line_arg === nothing ? line : Int(x.args[line_arg].line)
        if macro_name in _FORBIDDEN_MACROS
            _push_once!(findings, :APX_FORBIDDEN_MACRO, macro_line,
                        "$(macro_name) is forbidden in the verified subset")
        elseif macro_name === Symbol("@inbounds")
            if !verified
                _push_once!(findings, :APX_INBOUNDS_OUTSIDE_VERIFIED, macro_line,
                            "@inbounds is allowed only inside an @verified function")
            end
            if mutation_score === nothing || mutation_score < 95
                _push_once!(findings, :APX_MUTATION_GATE, macro_line,
                            "@inbounds requires mutation score >= 95%; supplied score is " *
                            (mutation_score === nothing ? "missing" : string(mutation_score, "%")))
            end
        elseif !(macro_name in _CONTRACT_MACROS) && verified
            _push_once!(findings, :APX_UNMODELED_MACRO, macro_line,
                        "macro $(macro_name) has no reviewed verifier elaborator")
        end

        # @verified is only a marker when it directly wraps a function. It is
        # never expanded/evaluated by this package.
        if macro_name === Symbol("@verified")
            payload = Any[arg for arg in x.args[2:end] if !(arg isa LineNumberNode)]
            if length(payload) != 1 || !_is_function_expr(only(payload))
                _push_once!(findings, :APX_INVALID_VERIFIED_MARKER, macro_line,
                            "@verified must directly annotate one function definition")
                for arg in x.args[2:end]
                    if arg isa LineNumberNode
                        line = Int(arg.line)
                        continue
                    end
                    line = _walk!(arg, false, mutation_score, line, findings)
                end
                return line
            end
            target = only(payload)
            return _walk!(target, true, mutation_score, line, findings; nested_function=true)
        end
    end

    # A nested function is a new proof boundary: an outer @verified annotation
    # does not implicitly certify locally defined methods.
    is_function_definition = x.head === :function || _is_short_function_definition(x)
    child_verified = is_function_definition && !nested_function ? false : verified
    current_line = line
    for arg in x.args
        if arg isa LineNumberNode
            current_line = Int(arg.line)
        else
            current_line = _walk!(arg, child_verified, mutation_score, current_line, findings)
        end
    end
    return current_line
end

"""
    audit_source(source; filename="<memory>", mutation_score=nothing)

Parse Julia source with JuliaSyntax.jl and enforce the initial fail-closed
source policy. `mutation_score` is an optional percentage in `0:100`; an
`@inbounds` expression requires a supplied score of at least 95. This is only a
policy gate: it does not discharge bounds VCs or establish a proof.

The audit intentionally does not execute macros or source code. Unknown macros
inside `@verified` bodies and unmodeled foreign calls are rejected.
"""
function audit_source(source::AbstractString; filename::AbstractString="<memory>",
                      mutation_score::Union{Nothing,Real}=nothing)
    if mutation_score !== nothing && !(0 <= mutation_score <= 100)
        throw(ArgumentError("mutation_score must be a percentage between 0 and 100"))
    end

    findings = Finding[]
    expr = try
        JuliaSyntax.parseall(Expr, String(source))
    catch err
        _push_once!(findings, :APX_PARSE_ERROR, 1,
                    "JuliaSyntax could not parse source: " * sprint(showerror, err))
        nothing
    end

    if expr !== nothing
        _walk!(expr, false, mutation_score, 1, findings)
    end

    status = isempty(findings) ? :policy_clean : :rejected
    return AuditReport(String(filename), status, findings)
end

"""Read and audit a Julia source file."""
function audit_file(path::AbstractString; kwargs...)
    return audit_source(read(path, String); filename=String(path), kwargs...)
end

end # module Apodeixis
