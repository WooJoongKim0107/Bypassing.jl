module Bypassing
export Bypassable, register, @register, @register_fn, Bypass, translate

using JLD2: save_object, load_object

# ============================================================================
# Bypassable AbstractType
# ============================================================================

"""
    abstract type Bypassable

Base type for structs that opt into the attribute-registration system.
A function registered for a `Bypassable` subtype can be accessed as if
it were a real field of that type.

# Example
```julia
struct Particle <: Bypassable
    x::Float64
    y::Float64
end

register(Particle, :speed_sq) do p
    p.x^2 + p.y^2
end

p = Particle(3.0, 4.0)
p.speed_sq   # 25.0
```

See [`register`](@ref) and [`@register`](@ref) for ways to add attributes.
"""
abstract type Bypassable end

# Marker function: dispatch target for registered attributes.
# A registered attribute (T, :name => f) becomes a method:
#     _attr(::Val{:name}, x::T) = f(x)
function _attr end

function Base.getproperty(x::T, s::Symbol) where T <: Bypassable
    if hasfield(T, s)
        return getfield(x, s)
    elseif hasmethod(_attr, Tuple{Val{s}, T})
        return _attr(Val(s), x)
    else
        error("type $(T) has no field $(s)")
    end
end

function Base.hasproperty(x::T, s::Symbol) where T <: Bypassable
    if hasfield(T, s)
        return true
    elseif hasmethod(_attr, Tuple{Val{s}, T})
        return true
    else
        return false
    end
end

"""
    register(f, T::Type, s::Symbol = Symbol(f))

Register function `f` as attribute `s` for type `T`, which must be a
[`Bypassable`](@ref) subtype. After registration, `x.s` on any `x::T`
returns `f(x)`.

If `s` is omitted it defaults to `Symbol(f)` — the function's name.

This function uses `@eval` internally to add a method to the dispatch
table at runtime. It is intended for **interactive use** (REPL, scripts).
**Do not use it at the top level of a package module**: the `@eval` call
runs during precompilation and may overwrite methods, breaking the
precompile cache. For package code, use the [`@register`](@ref) macro,
which emits the method definition as ordinary top-level code.

# Examples (interactive use)
```julia
# Plain function reference
speed_sq(p::Particle) = p.x^2 + p.y^2
register(speed_sq, Particle)

# do-block form (anonymous function)
register(Particle, :momentum) do p
    p.m * sqrt(p.x^2 + p.y^2)
end
```
"""
function register(f, T::Type, s::Symbol)
    T <: Bypassable || error("register: $T is not a subtype of Bypassable")
    @eval _attr(::Val{$(QuoteNode(s))}, x::$T) = $f(x)
    return f
end

register(f, T::Type) = register(f, T, Symbol(f))

"""
    @register function f(x::T) ... end
    @register f(x::T) = ...

Define a function and register it as an attribute of `T` (which must be
a [`Bypassable`](@ref) subtype). Equivalent in effect to writing the
function definition followed by `register(f, T, :f)`.

Unlike [`register`](@ref), this macro emits the registration as an
ordinary top-level method definition, so it is **safe to use inside a
package module**. Precompilation handles it like any other method.

Only the method introduced by this definition is registered. To register
additional methods on other `Bypassable` types, place `@register` in front
of each definition.

# Examples
```julia
@register function angle(p::Particle)
    atan(p.y, p.x) |> rad2deg
end

@register radius(p::Particle) = sqrt(p.x^2 + p.y^2)
```
"""
macro register(funcdef)
    # Accept both `function f(...) ... end` (head :function) and
    # short form `f(...) = ...` (head :(=)).
    if !(funcdef isa Expr) || !(funcdef.head === :function || funcdef.head === :(=))
        error("@register expects a function definition (long or short form)")
    end
    sig = funcdef.args[1]
    if !(sig isa Expr) || sig.head !== :call
        error("@register: could not parse function signature from $(sig)")
    end
    length(sig.args) >= 2 || error("@register: function must take at least one argument")
    fname = sig.args[1]
    fname isa Symbol || error("@register: function name must be a plain identifier, got $(fname)")
    first_arg = sig.args[2]
    if !(first_arg isa Expr && first_arg.head === :(::) && length(first_arg.args) == 2)
        error("@register: first argument must be type-annotated, e.g. `x::Particle`")
    end
    Tname = first_arg.args[2]
    # Emit two top-level definitions:
    #   1. The user's function, as written.
    #   2. A method on Bypassing._attr that dispatches to it.
    # This avoids @eval entirely, so precompilation handles both like any
    # other ordinary method definition.
    return quote
        $(esc(funcdef))
        function $(GlobalRef(@__MODULE__, :_attr))(::Val{$(QuoteNode(fname))}, x::$(esc(Tname)))
            $(esc(fname))(x)
        end
    end
end

"""
    @register_fn f T

Register an already-defined function `f` as an attribute of `T` (which must
be a [`Bypassable`](@ref) subtype) under the attribute name `:f`. After
registration, `x.f` on any `x::T` returns `f(x)`.

Unlike [`register`](@ref), this macro emits a plain method definition so it
is **safe to use inside a package module**. Use it when `f` is defined
separately — typically when extending a function imported from another module.

# Example
```julia
function Commons.sigma(rec::Record)
    action(rec) .|> sigma
end
@register_fn sigma Record   # rec.sigma now works
```

See [`@register`](@ref) for the combined define-and-register form.
"""
macro register_fn(fname, Tname)
    fname isa Symbol || error("@register_fn: first argument must be a plain function name")
    return quote
        function $(GlobalRef(@__MODULE__, :_attr))(::Val{$(QuoteNode(fname))}, x::$(esc(Tname)))
            $(esc(fname))(x)
        end
    end
end

# ============================================================================
# Core Bypass Type
# ============================================================================

"""
    Bypass{T, N, A<:AbstractArray{T, N}} <: AbstractArray{T, N}

An `AbstractArray` wrapper that forwards property access to its elements.

For any property name `s` other than `:data`, `bp.s` evaluates to
`Bypass(getproperty.(bp, s))` — i.e. each element is asked for its `s`
attribute, and the results are collected into a new `Bypass` of the
same shape.

The underlying array is accessible as `bp.data`.

# Constructors
```julia
Bypass(data::AbstractArray)         # wrap an existing array
Bypass(T, dims::NTuple{N, Int})     # uninitialized array of element type T
Bypass(T, dims::Int...)             # same, with separate dimension arguments
```

# Examples
```julia
struct Point
    x::Float64
    y::Float64
end

pts = Bypass([Point(i+0.0, j+0.0) for i in 1:2, j in 1:3])
size(pts)    # (2, 3)
pts.x        # 2×3 Bypass of x values
pts.y        # 2×3 Bypass of y values
pts[1, 2]    # Point(1.0, 2.0)
```

Standard `AbstractArray` operations (`map`, `filter`, `broadcast`,
indexing, `reshape`, etc.) all work as expected. Because `Bypass`
participates in the array protocol, third-party map-likes such as
`Distributed.pmap` and `ThreadsX.map` accept a `Bypass` directly.
"""
struct Bypass{T, N, A<:AbstractArray{T, N}} <: AbstractArray{T, N}
    data::A
    Bypass(data::A) where {T, N, A<:AbstractArray{T, N}} = new{T, N, A}(data)
end

Bypass(::Type{T}, shape::NTuple{N, Int}) where {T, N} = Bypass(Array{T, N}(undef, shape))
Bypass(::Type{T}, shape::Int...) where {T} = Bypass(T, shape)

Base.size(A::Bypass) = size(getfield(A, :data))
Base.axes(A::Bypass) = axes(getfield(A, :data))
Base.IndexStyle(::Type{Bypass{T, N, A}}) where {T, N, A} = IndexStyle(A)
Base.similar(A::Bypass, ::Type{T}, dims::Dims) where {T} = Bypass(similar(getfield(A, :data), T, dims))
Base.view(A::Bypass, I...) = Bypass(view(getfield(A, :data), to_indices(A, I)...))
@inline Base.setindex!(A::Bypass, v, I...) = setindex!(getfield(A, :data), v, to_indices(A, I)...)

function Base.getindex(A::Bypass, I...)
    inds = to_indices(A, I)
    r = getfield(A, :data)[inds...]
    return r isa AbstractArray ? Bypass(r) : r
end

function Base.getproperty(A::Bypass, s::Symbol)
    if s === :data
        return getfield(A, :data)
    else
        return Bypass(getproperty.(A, s))
    end
end

function Base.hasproperty(A::Bypass, s::Symbol)
    if s === :data
        return true
    else
        return !isempty(A) && hasproperty(first(A), s)
    end
end

function Base.reshape(A::Bypass, dims::Union{Int,AbstractUnitRange}...)
    Bypass(reshape(getfield(A, :data), dims...))
end

function Base.summary(io::IO, A::Bypass{T,N}) where {T,N}
    print(io, join(size(A), '×'), " Bypass{", T, ", ", N, "}")
end

# ============================================================================
# I/O System
# ============================================================================

"""
    translate(obj)             -> NamedTuple
    translate(obj, T::Type)    -> T

Convert between a struct and a `NamedTuple` representation by field name.

`translate(obj)` returns a `NamedTuple` whose names and values mirror the
fields of `obj` (in declaration order).

`translate(obj, T)` constructs a `T` by reading fields with the same names
from `obj` and passing them positionally to `T`'s constructor. This works
when `obj` already has those fields (e.g. when `obj` is a `NamedTuple`
loaded from disk).

These functions are used internally by [`Bypassing.save`](@ref) and
[`Bypassing.load`](@ref) so that JLD2 files do not depend on any
user-defined types.

# Example
```julia
struct Point
    x::Float64
    y::Float64
end

nt = translate(Point(1.0, 2.0))     # (x = 1.0, y = 2.0)
p  = translate(nt, Point)           # Point(1.0, 2.0)
```
"""
translate(obj::T) where T = NamedTuple{fieldnames(T)}(getfield(obj, f) for f in fieldnames(T))
translate(obj, ::Type{T}) where T = T((getfield(obj, f) for f in fieldnames(T))...)

"""
    Bypassing.save(filename, bp::Bypass)
    Bypassing.save(filename, arr::AbstractArray)

Save an array (or a `Bypass`) to a JLD2 file as a plain array of
`NamedTuple`s. Element types are not preserved on disk so the file can
be loaded into different struct definitions later (see [`load`](@ref)).

Not exported, to avoid clashing with other packages' `save` functions.
Call as `Bypassing.save`.
"""
function save(filename, self::Bypass)
    save_object(filename, translate.(getfield(self, :data)))
end

function save(filename, data::AbstractArray)
    save_object(filename, translate.(data))
end

"""
    Bypassing.load(filename)              -> Bypass{<:NamedTuple}
    Bypassing.load(T::Type, filename)     -> Bypass{T}
    Bypassing.load(f, filename)           -> Bypass

Load a JLD2 file saved by [`save`](@ref).

Without a transformer the elements are returned as raw `NamedTuple`s.
With a type `T`, each element is reconstructed as `T` via [`translate`](@ref).
With a function `f`, each element is reconstructed as `f(nt)`, where `nt`
is the raw `NamedTuple` read from disk. This third form is useful when
reconstruction needs custom logic beyond field-by-field copying.

Not exported. Call as `Bypassing.load`.

# Examples
```julia
nt_array  = Bypassing.load("particles.jld2")
particles = Bypassing.load(Particle, "particles.jld2")

# Custom reconstructor — e.g. derive mass from other fields
particles = Bypassing.load("particles.jld2") do nt
    Particle(nt.x, nt.y, nt.x * nt.y)
end
```
"""
load(filename::AbstractString) = Bypass(load_object(filename))

function load(::Type{T}, filename::AbstractString) where T
    loaded = load_object(filename)
    return T === NamedTuple ? Bypass(loaded) : Bypass(translate.(loaded, T))
end

function load(f, filename::AbstractString)
    loaded = load_object(filename)
    return Bypass(f.(loaded))
end

end
