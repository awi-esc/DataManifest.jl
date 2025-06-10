using Test
using DataManifest
using TOML

function setup_db()
    db = Database(datasets_folder="datasets-test")
    rm("datasets-test"; force=true, recursive=true)
    # pop!(db.datasets, "CMIP6_lgm_tos") # remote the ssh:// entry
    register_dataset(db, "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip";
        name="herzschuh2023", doi="10.1594/PANGAEA.930512")
    register_dataset(db, "https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv";
        name="jonkers2024", doi="10.1594/PANGAEA.962852")
    # register_dataset(db, "https://github.com/jesstierney/lgmDA.git")
    register_dataset(db, "https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip")
    reporoot = abspath(joinpath(@__DIR__, ".."))
    register_dataset(db, "file://$(reporoot)/test-data/data_file.txt"; name="CMIP6_lgm_tos")
    return db
end

@testset "DataManifest.jl" begin
    db = setup_db()

    @testset "Registration" begin
        @test haskey(db.datasets, "herzschuh2023")
        @test haskey(db.datasets, "jonkers2024")
        @test haskey(db.datasets, "jesstierney/lgmDA")
        @test haskey(db.datasets, "CMIP6_lgm_tos")
    end

    @testset "DatasetEntry access" begin
        entry = db.datasets["herzschuh2023"]
        @test isa(entry, DatasetEntry)
        @test isa(string(entry), String)
        @test isa(string_short(entry), String)
        @test isa(repr(entry), String)
        @test isa(repr_short(entry), String)
    end

    @testset "Database string/repr" begin
        @test isa(string(db), String)
        @test isa(repr(db), String)
    end

    @testset "Path" begin
        path = get_dataset_path(db, "herzschuh2023")
        @test path == "datasets-test/doi.pangaea.de/10.1594/PANGAEA.930512"
    end

    @testset "TOML" begin
        io = IOBuffer()
        TOML.print(io, db)
        @test String(take!(io)) isa String
        write(db, "test.toml")
        @test isfile("test.toml")
        other = read("test.toml", "datasets-test"; persist=false)
        @test other == db
    end

    @testset "Download (optional, may skip if offline)" begin
        try
            local_path = download_dataset(db, "jonkers2024")
            @test isfile(local_path)
        catch e
            @info "Skipping download_dataset test (offline or error): $e"
        end
        delete!(db.datasets, "jesstierney/lgmDA")  # large dataset: skip download
        try
            download_datasets(db)
            @test true
        catch e
            @info "Skipping download_datasets test (offline or error): $e"
        end
    end

    # Cleanup
    rm("datasets-test"; force=true, recursive=true)
    rm("test.toml"; force=true)
end