@testset ExtendedTestSet "chamfer" begin
    @testset ExtendedTestSet "chamfer" begin
        x = [
            1 1 0 0
            0 1 1 0
            0 1 0 1
            0 1 0 0
        ]
        tfm = Chamfer(x)
        answer = [
            0 0 3 4
            3 0 0 3
            3 0 3 0
            3 0 3 3
        ]
        @test transform(x, tfm) == answer
    end

    @testset ExtendedTestSet "chamfer" begin
        x = [
            1 1 0 0
            0 1 0 0
            0 1 0 0
            0 1 0 0
        ]
        tfm = Chamfer(x)
        answer = [
            0 0 3 6
            3 0 3 6
            3 0 3 6
            3 0 3 6
        ]
        @test transform(x, tfm) == answer
    end

    @testset ExtendedTestSet "chamfer" begin
        x1 = [
            1 1 0 0
            0 1 0 0
            0 1 0 0
            0 1 0 0
        ]
        x = cat(x1, x1; dims=3)
        tfm = Chamfer(x)

        a1 = [
            0 0 3 6
            3 0 3 6
            3 0 3 6
            3 0 3 6
        ]
        answer = cat(a1, a1; dims=3)
        @test transform(x, tfm) == answer
    end
end
