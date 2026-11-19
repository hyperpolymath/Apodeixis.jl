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

export Finding, AuditReport, PackageReport, audit_source, audit_file,
       audit_package, is_policy_clean

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

# Entries to foreign code. None has a checked ABI model yet.
const _FOREIGN_CALLS = Set((:ccall, :cglobal, :llvmcall))
const _FOREIGN_MACROS = Set((Symbol("@ccall"), Symbol("@cfunction")))

# Dynamic evaluation, code loading and raw object addresses. Every name that
# starts with `unsafe_` is forbidden as well (see `_is_forbidden_name`).
const _FORBIDDEN_CALLS = Set((
    :eval, :invokelatest, :invoke_in_world, :include, :include_string,
    :evalfile, :pointer_from_objref,
))

# snip: deny-list by name. A name that the program builds from a string at run
# time is not visible to a syntax audit; the planned typed-SSA frontend must
# replace this list with an allow-list.
_is_forbidden_name(name::Symbol) =
    name in _FOREIGN_CALLS || name in _FORBIDDEN_CALLS ||
    startswith(String(name), "unsafe_")

_referenced_name(x::Symbol) = x
_referenced_name(x::GlobalRef) = x.name
_referenced_name(_) = nothing

function _push_once!(findings::Vector{Finding}, code::Symbol, line::Int, message::String)
    # A malformed or deeply nested syntax tree can encounter the same policy
    # violation through multiple wrappers. Keep reports deterministic and tidy.
    any(f -> f.code === code && f.line == line && f.message == message, findings) ||
        push!(findings, Finding(code, max(line, 1), message))
    return nothing
end

# A forbidden name is rejected wherever the program refers to it, not only in
# call position: `const f = unsafe_load`, `Base.unsafe_load` and
# `getfield(Base, :unsafe_load)` must not hide it. A quoted symbol that is only
# data (`x = :eval`) is not a reference.
const _REFLECTIVE_LOOKUPS = Set((:getfield, :getproperty, :getglobal))

function _report_forbidden_name!(findings::Vector{Finding}, name::Symbol, line::Int)
    if name === :ccall
        _push_once!(findings, :APX_UNMODELED_CCALL, line,
                    "ccall is not yet verified; use a checked ABI wrapper only after the FFI phase")
    elseif name in _FOREIGN_CALLS
        _push_once!(findings, :APX_UNMODELED_CCALL, line,
                    "$(name) enters foreign code without a checked ABI model")
    else
        _push_once!(findings, :APX_DYNAMIC_ESCAPE, line,
                    "$(name) is forbidden in the closed verified subset")
    end
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

function _is_short_function_definition(x)
    x isa Expr && x.head === :(=) && !isempty(x.args) || return false
    signature = first(x.args)
    # Return types and type parameters can wrap the call signature in either order.
    while signature isa Expr && signature.head in (:(::), :where) && !isempty(signature.args)
        signature = first(signature.args)
    end
    return signature isa Expr && signature.head === :call
end
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
    elseif x.head === :global
        _push_once!(findings, :APX_GLOBAL_MUTATION, line,
                    "global declarations are outside the verified capability subset")
    elseif x.head === :foreigncall
        _push_once!(findings, :APX_UNMODELED_CCALL, line,
                    "lowered foreign calls require a checked Idris2/Zig ABI manifest")
    elseif x.head === :call && !isempty(x.args)
        callee = _callee_symbol(first(x.args))
        if callee isa Symbol && _is_forbidden_name(callee)
            _report_forbidden_name!(findings, callee, line)
        elseif callee in _REFLECTIVE_LOOKUPS
            for arg in x.args[2:end]
                if arg isa QuoteNode && arg.value isa Symbol && _is_forbidden_name(arg.value)
                    _report_forbidden_name!(findings, arg.value, line)
                end
            end
        end
    elseif x.head === :.
        member = _callee_symbol(x)
        if member isa Symbol && _is_forbidden_name(member)
            _report_forbidden_name!(findings, member, line)
        end
    end

    if x.head === :macrocall && !isempty(x.args)
        macro_name = _macro_symbol(first(x.args))
        line_arg = findfirst(arg -> arg isa LineNumberNode, x.args)
        macro_line = line_arg === nothing ? line : Int(x.args[line_arg].line)
        if macro_name in _FOREIGN_MACROS
            _push_once!(findings, :APX_UNMODELED_CCALL, macro_line,
                        "$(macro_name) enters foreign code without a checked ABI model")
        end
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
            name = _referenced_name(arg)
            if name isa Symbol && _is_forbidden_name(name)
                _report_forbidden_name!(findings, name, current_line)
            end
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
    return _audit(String(source), String(filename), mutation_score, nothing)
end

# Shared by `audit_source` and package mode. `prepare!`, when given, receives
# the parsed tree before the walk and may rewrite it (package mode removes the
# one permitted form of `include`). `audit_source` passes `nothing`.
function _audit(source::String, filename::String, mutation_score, prepare!)
    if mutation_score !== nothing && !(0 <= mutation_score <= 100)
        throw(ArgumentError("mutation_score must be a percentage between 0 and 100"))
    end

    findings = Finding[]
    expr = try
        JuliaSyntax.parseall(Expr, source)
    catch err
        _push_once!(findings, :APX_PARSE_ERROR, 1,
                    "JuliaSyntax could not parse source: " * sprint(showerror, err))
        nothing
    end

    if expr !== nothing
        prepare! === nothing || prepare!(expr)
        _walk!(expr, false, mutation_score, 1, findings)
    end

    status = isempty(findings) ? :policy_clean : :rejected
    return AuditReport(filename, status, findings)
end

"""Read and audit a Julia source file."""
function audit_file(path::AbstractString; kwargs...)
    return audit_source(read(path, String); filename=String(path), kwargs...)
end

# ---------------------------------------------------------------------------
# Package mode
# ---------------------------------------------------------------------------

"""
Result of `audit_package`: the root file, one `AuditReport` per reached file
(in the order reached), package-level findings, and the `.jl` files under the
root directory that no `include` reaches. Unreached files are listed so that an
unaudited file is visible; they are not findings and do not change `status`.
Package-level findings name the including file in their message and carry the
line of the `include` in that file.
"""
struct PackageReport
    root::String
    status::Symbol
    reports::Vector{AuditReport}
    findings::Vector{Finding}
    unreached::Vector{String}
end

"""True when every reached file is policy clean and there is no package-level finding."""
is_policy_clean(report::PackageReport) =
    report.status === :policy_clean &&
    isempty(report.findings) && all(is_policy_clean, report.reports)

# The one permitted form: `include("literal.jl")`, one plain string literal
# argument, as a statement directly at top level or directly in a module body.
_is_literal_include(x) = x isa Expr && x.head === :call && length(x.args) == 2 &&
                         x.args[1] === :include && x.args[2] isa String

# The statement list of a `module` or `baremodule`, or `nothing`. A docstring on
# the module (JuliaSyntax writes it as a `Core.@doc` call around the module) does
# not change where the module body is; no other macro is looked through.
function _module_body(x)
    x isa Expr || return nothing
    if x.head === :macrocall && length(x.args) == 4 && x.args[1] isa GlobalRef &&
       x.args[1].mod === Core && x.args[1].name === Symbol("@doc")
        x = x.args[4]
        x isa Expr || return nothing
    end
    x.head === :module && length(x.args) >= 3 && x.args[end] isa Expr &&
        x.args[end].head === :block ? x.args[end].args : nothing
end

# Remove each permitted include from the tree, record it, and leave `nothing`
# in its place. Every other `include` stays in the tree and the walk flags it.
function _extract_includes!(stmts::Vector{Any}, found::Vector{Tuple{String,Int}})
    line = 1
    for i in eachindex(stmts)
        arg = stmts[i]
        if arg isa LineNumberNode
            line = Int(arg.line)
        elseif _is_literal_include(arg)
            push!(found, (arg.args[2], line))
            stmts[i] = nothing
        else
            body = _module_body(arg)
            body === nothing || _extract_includes!(body, found)
        end
    end
    return found
end

function _extract_includes!(expr::Expr)
    found = Tuple{String,Int}[]
    expr.head === :toplevel && _extract_includes!(expr.args, found)
    return found
end

_inside_dir(path::AbstractString, dir::AbstractString) =
    path == dir || startswith(path, dir * Base.Filesystem.path_separator)

"""
    audit_package(root_file; mutation_score=nothing)

Audit a package from its root file. The root and every file that a permitted
`include` reaches are audited with the rules of `audit_source`. Only one form
of `include` is permitted, and only here: a call with one plain string literal
argument, written as a statement at top level or directly in a `module` or
`baremodule` body. The path must be relative, end in `.jl`, resolve against the
directory of the including file, and stay inside the root file's directory
after `realpath`. Every other `include` is `APX_DYNAMIC_ESCAPE`.

Package-level finding codes: `APX_INCLUDE_PATH` (path breaks a form rule),
`APX_INCLUDE_OUTSIDE_ROOT`, `APX_INCLUDE_MISSING`, `APX_INCLUDE_DUPLICATE`
(file reached twice), `APX_INCLUDE_CYCLE`, `APX_PACKAGE_SCAN_ERROR` (a directory
could not be listed). This is a source-policy audit, not a proof.
"""
function audit_package(root_file::AbstractString;
                       mutation_score::Union{Nothing,Real}=nothing)
    if mutation_score !== nothing && !(0 <= mutation_score <= 100)
        throw(ArgumentError("mutation_score must be a percentage between 0 and 100"))
    end
    root = String(root_file)
    reports = AuditReport[]
    findings = Finding[]

    if !isfile(root)
        push!(findings, Finding(:APX_INCLUDE_MISSING, 1,
                                "root file does not exist or is not a regular file: $root"))
        return PackageReport(root, :rejected, reports, findings, String[])
    end
    real_root = realpath(root)
    root_dir = dirname(real_root)
    visited = Set{String}()
    stack = String[]

    relname(p) = relpath(p, root_dir)

    function visit(path::String, real::String)
        push!(visited, real)
        push!(stack, real)
        found = Tuple{String,Int}[]
        report = _audit(read(real, String), path, mutation_score,
                        expr -> append!(found, _extract_includes!(expr)))
        push!(reports, report)
        here = dirname(real)
        who = relname(real)
        for (rel, line) in found
            fail(code, msg) = push!(findings, Finding(code, max(line, 1), "$who: $msg"))
            if isempty(rel) || occursin('\0', rel) || isabspath(rel) || !endswith(rel, ".jl")
                fail(:APX_INCLUDE_PATH,
                     "include path must be relative, non-empty and end in .jl: $(repr(rel))")
                continue
            end
            cand = normpath(joinpath(here, rel))
            if ispath(cand)
                rp = realpath(cand)
                if !_inside_dir(rp, root_dir)
                    fail(:APX_INCLUDE_OUTSIDE_ROOT,
                         "include leaves the package directory: $(repr(rel))")
                elseif !isfile(rp)
                    fail(:APX_INCLUDE_MISSING, "include is not a regular file: $(repr(rel))")
                elseif rp in stack
                    fail(:APX_INCLUDE_CYCLE,
                         "include cycle: $(repr(rel)) is already being included")
                elseif rp in visited
                    fail(:APX_INCLUDE_DUPLICATE,
                         "file is included more than once: $(repr(rel))")
                else
                    visit(cand, rp)
                end
            elseif !_inside_dir(cand, root_dir)
                fail(:APX_INCLUDE_OUTSIDE_ROOT,
                     "include leaves the package directory: $(repr(rel))")
            else
                fail(:APX_INCLUDE_MISSING, "included file does not exist: $(repr(rel))")
            end
        end
        pop!(stack)
        return nothing
    end

    visit(root, real_root)

    unreached = String[]
    scan_error(err) = push!(findings, Finding(:APX_PACKAGE_SCAN_ERROR, 1,
                                              "could not list a directory: " * sprint(showerror, err)))
    for (dir, _, files) in walkdir(root_dir; onerror=scan_error)
        for f in files
            endswith(f, ".jl") || continue
            p = joinpath(dir, f)
            rp = try realpath(p) catch; p end
            rp in visited || push!(unreached, relname(p))
        end
    end
    sort!(unreached)

    clean = isempty(findings) && all(is_policy_clean, reports)
    return PackageReport(root, clean ? :policy_clean : :rejected, reports, findings, unreached)
end

end # module Apodeixis
