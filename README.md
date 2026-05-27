# Bypassing.jl

A small Julia package providing two complementary tools for working with
collections of structured data:

- **`Bypassable`** — an abstract type that lets you register functions as
  "virtual attributes" of a struct, accessible with `.` syntax.
- **`Bypass`** — an `AbstractArray` wrapper that broadcasts property
  access to its elements.

Together they let you write code like `particles.speed_sq` where
`speed_sq` is a function registered on `Particle`, and have it
evaluate element-wise across the whole collection.

---

## Installation

This package is not yet registered in the General registry. Install it directly
from GitHub:

```julia
pkg> add https://github.com/WooJoongKim0107/Bypassing.jl
```

Or, for local development:

```julia
pkg> dev /path/to/Bypassing.jl
```

---

## `Bypassable` — Attribute Registration

`Bypassable` is an abstract type. Any struct that inherits from it can
have functions registered as accessible attributes.

```julia
using Bypassing

struct Particle <: Bypassable
    x::Float64
    y::Float64
    m::Float64
end
```

### Registering attributes

Two main forms:

```julia
# Inside a package module — use the @register macro.
# It emits a regular top-level method definition, so precompilation
# handles it like any other code.
@register function angle(p::Particle)
    atan(p.y, p.x) |> rad2deg
end

@register radius(p::Particle) = sqrt(p.x^2 + p.y^2)

# Interactively (REPL, scripts) — the register function is more flexible.
# It accepts already-defined functions and supports do-block syntax.

speed_sq(p::Particle) = p.x^2 + p.y^2
register(speed_sq, Particle)

register(Particle, :momentum) do p
    p.m * sqrt(p.x^2 + p.y^2)
end
```

> **Note.** Do not call `register` at the top level of a package module.
> It uses `@eval` internally to add methods at runtime, which conflicts
> with precompilation. Use `@register` inside package code; use `register`
> for interactive work or for cases where the registration is genuinely
> dynamic (e.g. choosing what to register based on a runtime condition,
> inside a function that you only ever call from the REPL).

After registration, the attributes are accessed like real fields:

```julia
p = Particle(3.0, 4.0, 2.0)
p.x          # 3.0  (real field)
p.speed_sq   # 25.0 (registered)
p.momentum   # 10.0
p.angle      # 53.13...
p.radius     # 5.0
```

### How it works

`register` adds a method to an internal marker function `_attr`, keyed
on a `Val{:name}` and the target type. When you write `p.speed_sq`,
Julia's getproperty hook calls `_attr(Val(:speed_sq), p)`, which
dispatches to the registered method via the usual multiple-dispatch
machinery.

Because dispatch is used, attributes registered on a supertype are
automatically visible on all subtypes — no extra registration needed.

```julia
abstract type Animal <: Bypassable end

@register sound(a::Animal) = "generic noise"

struct Dog <: Animal end
Dog().sound   # "generic noise"  — inherited automatically
```

---

## `Bypass` — Property Bypassing Arrays

`Bypass` wraps an `AbstractArray`. For any property name other than
`:data` (which exposes the underlying array), property access is
forwarded element-wise:

```julia
particles = Bypass([Particle(i+0.0, j+0.0, 1.0) for i in 1:3, j in 1:3])

particles.x          # 3×3 Bypass of x values
particles.speed_sq   # 3×3 Bypass of registered attribute values
```

The result is itself a `Bypass`, so accesses can chain naturally and
participate in further computations.

### Standard array operations

`Bypass <: AbstractArray`, so the full array protocol works:

```julia
size(particles)              # (3, 3)
particles[1, 2]              # a Particle
particles[1, :]              # a 1D Bypass slice
reshape(particles, 9)        # flatten to 1D
map(p -> p.x^2, particles)   # returns a Bypass (via similar)
```

Third-party `map`-likes such as `Distributed.pmap`, `ThreadsX.map`, etc.
accept a `Bypass` directly:

```julia
using Distributed
heavy = pmap(particles) do p
    sleep(0.05)
    p.x ^ p.y
end
```

### Constructors

```julia
Bypass(data)            # wrap an existing array
Bypass(Float64, 10, 20) # 10×20 uninitialized array of Float64
Bypass(Float64, (3, 4)) # tuple form
```

---

## I/O

Save and load functions are **not exported**, to avoid clashing with
the `save`/`load` exported by other packages (GLMakie, FileIO, JLD2,
etc.). Call them with the module prefix.

```julia
Bypassing.save("particles.jld2", particles)

# Load as raw NamedTuples (default)
nt_array = Bypassing.load("particles.jld2")

# Load as a specific type — reconstructs each element via translate()
particles = Bypassing.load(Particle, "particles.jld2")

# Load with a custom reconstructor — for any logic that doesn't reduce
# to plain field-by-field copying
particles = Bypassing.load("particles.jld2") do nt
    Particle(nt.x, nt.y, nt.x * nt.y)   # derive mass from x and y
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

## Working with elements ergonomically

A common pattern is element-wise computation over a `Bypass`. Because
`Bypass` is just an `AbstractArray`, the standard tools apply:

```julia
# Single attribute access — already broadcast for free
speeds = particles.speed_sq

# General element-wise computation
mags = map(p -> sqrt(p.x^2 + p.y^2), particles)

# Filtering
fast = particles[map(p -> p.x > 50, particles)]
# or equivalently
fast = filter(p -> p.x > 50, particles)
```

If you find yourself repeating a computation, register it as an attribute:

```julia
@register magnitude(p::Particle) = sqrt(p.x^2 + p.y^2)

# Now this works directly:
particles.magnitude
```

---

## Exported names

| Name             | Kind        | Purpose                              |
|------------------|-------------|--------------------------------------|
| `Bypassable`     | abstract    | base type for attribute registration |
| `register`       | function    | register a function as an attribute  |
| `@register`      | macro       | define and register in one step      |
| `@register_fn`   | macro       | register an already-defined function |
| `Bypass`         | struct      | array with element-wise property access |
| `translate`      | function    | struct ↔ NamedTuple conversion       |

Not exported (call with `Bypassing.` prefix):

| Name              | Kind     | Purpose              |
|-------------------|----------|----------------------|
| `Bypassing.save`  | function | JLD2 serialization   |
| `Bypassing.load`  | function | JLD2 deserialization |

All exported names also have inline docstrings; use `?Bypassable`, `?register`,
etc. at the REPL for details.

---

## License

[MIT](LICENSE)
