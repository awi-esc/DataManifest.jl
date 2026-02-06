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
        path = get_dataset_path(db, "lgmDA")
        @test path == "datasets-test/github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"
        path = get_dataset_path(db, "tierney", partial=true)
        @test path == "datasets-test/github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"

    end

    @testset "TOML" begin
        io = IOBuffer()
        TOML.print(io, db)
        @test String(take!(io)) isa String
        write(db, "test.toml")
        @test isfile("test.toml")
        other = read_dataset("test.toml", "datasets-test"; persist=false)
        @test other == db
    end

    @testset "Command-based entry (templating)" begin
        # Use a db with datasets_toml so project_root is the package dir (not the test env)
        pkg_root = abspath(joinpath(@__DIR__, ".."))
        db_cmd = Database(joinpath(pkg_root, "Datasets.toml"), "datasets-test"; persist=false)
        register_dataset(db_cmd, ""; name="cmd_dataset", key="cmd-test/templating", command="julia --startup-file=no $(joinpath(@__DIR__, "write_dummy.jl")) \$download_path \$key", skip_checksum=true)
        local_path = download_dataset(db_cmd, "cmd_dataset")
        # File is under project_root when command runs with dir=project_root
        expected_file = joinpath(pkg_root, local_path, "dummy.txt")
        @test isfile(expected_file)
        @test read(expected_file, String) == "cmd-test/templating"
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

    @testset "delete_dataset" begin
        reporoot = abspath(joinpath(@__DIR__, ".."))
        # Ensure CMIP6_lgm_tos (file://) is downloaded
        try
            download_dataset(db, "CMIP6_lgm_tos")
        catch
        end
        path = get_dataset_path(db, "CMIP6_lgm_tos")
        @test haskey(db.datasets, "CMIP6_lgm_tos")
        # keep_cache=true: remove from db but keep on disk
        delete_dataset(db, "CMIP6_lgm_tos"; keep_cache=true, persist=false)
        @test !haskey(db.datasets, "CMIP6_lgm_tos")
        @test isfile(path)
        # Re-register and re-download for keep_cache=false test
        register_dataset(db, "file://$(reporoot)/test-data/data_file.txt"; name="CMIP6_lgm_tos")
        try
            download_dataset(db, "CMIP6_lgm_tos")
        catch
        end
        path = get_dataset_path(db, "CMIP6_lgm_tos")
        # keep_cache=false: remove from db and disk
        delete_dataset(db, "CMIP6_lgm_tos"; keep_cache=false, persist=false)
        @test !haskey(db.datasets, "CMIP6_lgm_tos")
        @test !isfile(path) && !isdir(path)
    end

    @testset "download_dataset overwrite" begin
        try
            download_dataset(db, "jonkers2024")
            # overwrite=true should not error (re-downloads)
            download_dataset(db, "jonkers2024"; overwrite=true)
            @test isfile(get_dataset_path(db, "jonkers2024"))
        catch e
            @info "Skipping overwrite test (offline or error): $e"
        end
    end

    # Cleanup
    rm("datasets-test"; force=true, recursive=true)
    rm("test.toml"; force=true)
end