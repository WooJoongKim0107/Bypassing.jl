"""
Test coverage includes:

- `Bypassable` field access, registered computed attributes, `hasproperty`,
  and missing-property errors.
- `register` and `@register` attribute registration paths.
- `Bypass` array behavior: size, axes, indexing, slicing, property forwarding,
  `reshape`, `map`, and `filter`.
- `Bypass` constructors and mutation through `setindex!`.
- `translate` conversions between structs and `NamedTuple`s.
- `Bypassing.save` / `Bypassing.load` JLD2 round trips, including typed and
  custom reconstruction.
"""

using Bypassing
using Test

struct TestParticle <: Bypassable
    x::Float64
    y::Float64
end

@register radius(p::TestParticle) = sqrt(p.x^2 + p.y^2)

@register function angle(p::TestParticle)
    atan(p.y, p.x) |> rad2deg
end

@testset "Bypassable attributes" begin
    p = TestParticle(3.0, 4.0)

    @test p.x == 3.0
    @test p.radius == 5.0
    @test p.angle ≈ 53.13010235415598
    @test hasproperty(p, :x)
    @test hasproperty(p, :radius)
    @test !hasproperty(p, :missing)
    @test_throws ErrorException p.missing
end

@testset "Dynamic registration" begin
    struct DynamicParticle <: Bypassable
        x::Int
        y::Int
    end

    register(DynamicParticle, :manhattan) do p
        abs(p.x) + abs(p.y)
    end

    @test DynamicParticle(-2, 5).manhattan == 7
end

@testset "Bypass array behavior" begin
    particles = Bypass([TestParticle(i, j) for i in 1.0:2.0, j in 3.0:5.0])

    @test size(particles) == (2, 3)
    @test axes(particles) == (Base.OneTo(2), Base.OneTo(3))
    @test particles.data isa Matrix{TestParticle}
    @test particles[1, 2] == TestParticle(1.0, 4.0)
    @test particles[:, 1] isa Bypass
    @test particles[:, 1].data == TestParticle.(1.0:2.0, 3.0)

    @test particles.x isa Bypass
    @test particles.x.data == [1.0 1.0 1.0; 2.0 2.0 2.0]
    @test particles.y.data == [3.0 4.0 5.0; 3.0 4.0 5.0]
    @test particles.radius.data ≈ [sqrt(10) sqrt(17) sqrt(26); sqrt(13) sqrt(20) sqrt(29)]
    @test hasproperty(particles, :data)
    @test hasproperty(particles, :radius)
    @test !hasproperty(particles, :missing)

    flattened = reshape(particles, 6)
    @test flattened isa Bypass
    @test size(flattened) == (6,)

    doubled_x = map(p -> 2p.x, particles)
    @test doubled_x isa Bypass
    @test doubled_x.data == [2.0 2.0 2.0; 4.0 4.0 4.0]

    selected = filter(p -> p.radius > 4.0, particles)
    @test selected isa Bypass
    @test selected.radius.data == [sqrt(17), sqrt(20), sqrt(26), sqrt(29)]
end

@testset "Constructors and mutation" begin
    particles = Bypass(TestParticle, 2, 1)
    particles[1, 1] = TestParticle(3.0, 4.0)
    particles[2, 1] = TestParticle(5.0, 12.0)

    @test particles isa Bypass{TestParticle, 2}
    @test particles.radius.data == [5.0; 13.0;;]

    vector = Bypass(Int, (3,))
    vector[1] = 10
    vector[2] = 20
    vector[3] = 30
    @test vector.data == [10, 20, 30]
end

@testset "Translation and JLD2 round trip" begin
    p = TestParticle(3.0, 4.0)
    nt = translate(p)

    @test nt == (; x = 3.0, y = 4.0)
    @test translate(nt, TestParticle) == p

    mktempdir() do dir
        filename = joinpath(dir, "particles.jld2")
        particles = Bypass([TestParticle(1.0, 2.0), TestParticle(3.0, 4.0)])

        Bypassing.save(filename, particles)

        loaded_nt = Bypassing.load(filename)
        @test loaded_nt isa Bypass
        @test loaded_nt.data == translate.(particles.data)

        loaded_particles = Bypassing.load(TestParticle, filename)
        @test loaded_particles isa Bypass
        @test loaded_particles.data == particles.data

        loaded_custom = Bypassing.load(filename) do row
            TestParticle(row.x + 1, row.y + 1)
        end
        @test loaded_custom.data == [TestParticle(2.0, 3.0), TestParticle(4.0, 5.0)]
    end
end
