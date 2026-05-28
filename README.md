# PropertyArrays.jl

A small Julia package for accessing element attributes through a container.

In Julia, accessing the same property from every element of an array is
usually written as an explicit broadcast:

```julia
getproperty.(A, :x)
```

`PropertyArray` provides a wrapper where property access is forwarded to the
elements:

```julia
bp = PropertyArray(A)
bp.x
```

This is equivalent to:

```julia
getproperty.(A, :x)
```

Other array operations are intended to behave as they do for the wrapped
array. Indexing, `size`, `axes`, `reshape`, `map`, `filter`, and similar
operations remain ordinary array operations; the main special case is
`getproperty`. The original array is available as `.data`.

`PropertyObject` is a small companion interface for registering computed
attributes on element types. For example, a calculation such as
`angle.(A)` can be exposed as `PropertyArray(A).angle` after registration.

The package provides two complementary tools:

- **`PropertyArray`** — an `AbstractArray` wrapper that forwards property
  access to its elements.
- **`PropertyObject`** — an abstract type that lets you register functions as
  "virtual attributes" of a struct, accessible with `.` syntax.

---

## Example

```julia
using PropertyArrays

struct Particle <: PropertyObject
    x::Float64
    y::Float64
end

@register angle(p::Particle) = atan(p.y, p.x) |> rad2deg
@register radius(p::Particle) = sqrt(p.x^2 + p.y^2)

particles = PropertyArray([Particle(i+0.0, j+0.0) for i in 1:2, j in 1:3])
```

Here `x` and `y` are particle positions. A plain array would use
`getproperty.(A, :x)` to collect all `x` positions. A `PropertyArray` wrapper
uses property syntax:

```julia
particles.x
```

```text
2×3 PropertyArray{Float64, 2}:
 1.0  1.0  1.0
 2.0  2.0  2.0
```

Registered attributes use the same property syntax:

```julia
particles.angle
```

```text
2×3 PropertyArray{Float64, 2}:
 45.0     63.4349  71.5651
 26.5651  45.0     56.3099
```

On a single element, registered attributes are also available through the
same syntax:

```julia
p = Particle(3.0, 4.0)

p.x
p.radius
p.angle
```

```text
3.0
5.0
53.13010235415598
```

The same attributes can be used in ordinary array operations:

```julia
queried = filter(particles) do p
    p.angle >= 45 && p.radius < 3
end

queried.radius
```

```text
3-element PropertyArray{Float64, 1}:
 1.4142135623730951
 2.23606797749979
 2.8284271247461903
```

The filtered result is still a `PropertyArray`, so it can be passed to later
array-style work. For example, if each selected particle requires a
heavier calculation:

```julia
using Distributed

results = pmap(queried) do p
    # Replace this with the expensive per-particle computation.
    (; angle = p.angle, radius = p.radius)
end
```

---

## Registering Attributes

`PropertyObject` is an abstract type. Any struct that inherits from it can
have functions registered as accessible attributes.

### In Package Code

Use `@register`. It emits ordinary top-level method definitions, so
precompilation handles it like other Julia code.

```julia
@register function angle(p::Particle)
    atan(p.y, p.x) |> rad2deg
end

@register radius(p::Particle) = sqrt(p.x^2 + p.y^2)
```

### In the REPL or Scripts

Use `register` when working interactively or when the registration is
genuinely dynamic.

```julia
radius_sq(p::Particle) = p.x^2 + p.y^2
register(radius_sq, Particle)

register(Particle, :is_right_side) do p
    p.x > 0
end
```

After registration, the attributes are accessed through property syntax:

```julia
p = Particle(3.0, 4.0)

p.radius_sq
p.is_right_side
```

```text
25.0
true
```

> **Note.** Do not call `register` at the top level of a package module.
> It uses `@eval` internally to add methods at runtime, which conflicts
> with precompilation. Use `@register` inside package code; use `register`
> for interactive work or for cases where the registration is genuinely
> dynamic.

---

## Array Behavior

`PropertyArray` wraps an `AbstractArray`. The wrapped array is available as
`.data`. For any other property name, property access is forwarded
element-wise:

```julia
particles.x       # PropertyArray of x values
particles.angle   # PropertyArray of registered angle values
```

For operations other than property access, `PropertyArray` follows the ordinary
`AbstractArray` interface and preserves the behavior of the wrapped
container where possible:

```julia
size(particles)              # (2, 3)
particles[1, 2]              # Particle(1.0, 2.0)
particles[1, :]              # a 1D PropertyArray slice
reshape(particles, 6)        # flatten to 1D
map(p -> p.x^2, particles)   # returns a PropertyArray via similar
```

Code that works with arrays generally accepts a `PropertyArray` as well. This
includes standard tools such as `map` and `filter`, and third-party
map-like functions such as `Distributed.pmap` or `ThreadsX.map`.

Constructors:

```julia
PropertyArray(data)            # wrap an existing array
PropertyArray(Float64, 10, 20) # 10x20 uninitialized array of Float64
PropertyArray(Float64, (3, 4)) # tuple form
```

---

## How Attribute Registration Works

`register` adds a method to an internal marker function `_attr`, keyed
on a `Val{:name}` and the target type. When you write `p.angle`, Julia's
`getproperty` hook calls `_attr(Val(:angle), p)`, which dispatches to the
registered method via the usual multiple-dispatch machinery.

Because dispatch is used, attributes registered on a supertype are
automatically visible on all subtypes:

```julia
abstract type Animal <: PropertyObject end

@register sound(a::Animal) = "generic noise"

struct Dog <: Animal end

Dog().sound
```

```text
"generic noise"
```

---

## I/O

Save and load functions are **not exported**, to avoid clashing with
the `save`/`load` exported by other packages (GLMakie, FileIO, JLD2,
etc.). Call them with the module prefix.

```julia
PropertyArrays.save("particles.jld2", particles)

# Load as raw NamedTuples (default)
nt_array = PropertyArrays.load("particles.jld2")

# Load as a specific type; reconstructs each element via translate()
particles = PropertyArrays.load(Particle, "particles.jld2")

# Load with a custom reconstructor
particles = PropertyArrays.load("particles.jld2") do nt
    Particle(nt.x, nt.y)
end
```

The on-disk format is a plain array of `NamedTuple`s, so files are
independent of any user-defined types. You can load data into a different
struct definition than the one that saved it, as long as the field names
line up.

### `translate`

`translate(obj)` and `translate(obj, T)` are the conversion helpers used
internally:

```julia
nt = translate(Point(1.0, 2.0))     # (x = 1.0, y = 2.0)
p  = translate(nt, Point)           # Point(1.0, 2.0)
```

---

## Exported Names

| Name             | Kind        | Purpose                                |
|------------------|-------------|----------------------------------------|
| `PropertyArray`  | struct      | array with element-wise property access |
| `PropertyObject` | abstract    | base type for attribute registration   |
| `register`       | function    | register a function as an attribute    |
| `@register`      | macro       | define and register in one step        |
| `@register_fn`   | macro       | register an already-defined function   |
| `translate`      | function    | struct <-> NamedTuple conversion       |

Not exported (call with `PropertyArrays.` prefix):

| Name              | Kind     | Purpose              |
|-------------------|----------|----------------------|
| `PropertyArrays.save` | function | JLD2 serialization   |
| `PropertyArrays.load` | function | JLD2 deserialization |

All exported names also have inline docstrings; use `?PropertyObject`,
`?register`, etc. at the REPL for details.

---

## Installation

This package is not yet registered in the General registry. Install it
directly from GitHub:

```julia
pkg> add https://github.com/WooJoongKim0107/PropertyArrays.jl
```

Or, for local development:

```julia
pkg> dev /path/to/PropertyArrays.jl
```

---

## License

[MIT](LICENSE)
