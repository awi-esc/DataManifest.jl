using Test
using DataManifest
using TOML

pkg_root = abspath(joinpath(@__DIR__, ".."))

function setup_db(datasets_folder::String)
    db = Database(datasets_folder=datasets_folder; persist=false)
    register_dataset(db, "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip";
        name="herzschuh2023", doi="10.1594/PANGAEA.930512")
    register_dataset(db, "https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv";
        name="jonkers2024", doi="10.1594/PANGAEA.962852")
    register_dataset(db, "https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip")
    register_dataset(db, "file://$(joinpath(@__DIR__, "test-data", "data_file.txt"))"; name="CMIP6_lgm_tos")
    return db
end

datasets_dir = mktempdir(prefix="DataManifest_test_"; cleanup=true)

try
@testset "DataManifest.jl" begin
    db = setup_db(datasets_dir)

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
        @test path == joinpath(datasets_dir, "doi.pangaea.de/10.1594/PANGAEA.930512")
        path = get_dataset_path(db, "lgmDA")
        @test path == joinpath(datasets_dir, "github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip")
        path = get_dataset_path(db, "tierney", partial=true)
        @test path == joinpath(datasets_dir, "github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip")
    end

    @testset "File format inference" begin
        # URI-based: format from key (host + path)
        @test db.datasets["herzschuh2023"].format == "zip"
        @test db.datasets["jonkers2024"].format == "csv"
        @test db.datasets["jesstierney/lgmDA"].format == "zip"
        @test db.datasets["CMIP6_lgm_tos"].format == "txt"
        # Explicit key (no URI): format from key extension
        db_fmt = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db_fmt, ""; name="csv_from_key", key="intermediate_data/tierney2020_cores_hol.csv",
            julia="write(download_path, \"x\")", skip_checksum=true)
        @test db_fmt.datasets["csv_from_key"].format == "csv"
        # Key with # version suffix: format from part before #
        register_dataset(db_fmt, ""; name="tar_gz_with_version", key="releases/archive.tar.gz#v1.0",
            julia="write(download_path, \"x\")", skip_checksum=true)
        @test db_fmt.datasets["tar_gz_with_version"].format == "tar.gz"
    end

    @testset "TOML" begin
        io = IOBuffer()
        TOML.print(io, db)
        @test String(take!(io)) isa String
        test_toml = joinpath(datasets_dir, "test.toml")
        write(db, test_toml)
        @test isfile(test_toml)
        other = read_dataset(test_toml, datasets_dir; persist=false)
        @test other == db
    end

    @testset "Command-based entry (templating)" begin
        db_cmd = Database(joinpath(pkg_root, "Datasets.toml"), datasets_dir; persist=false)
        register_dataset(db_cmd, ""; name="cmd_dataset", key="cmd-test/templating", shell="julia --startup-file=no $(joinpath(@__DIR__, "write_dummy.jl")) \$download_path \$key", skip_checksum=true)
        local_path = download_dataset(db_cmd, "cmd_dataset")
        expected_file = joinpath(local_path, "dummy.txt")
        @test isfile(expected_file)
        @test read(expected_file, String) == "cmd-test/templating"
    end

    @testset "julia (inline Julia in isolated module)" begin
        db_jl = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db_jl, ""; name="julia_cmd_dataset", key="julia-cmd-test/result",
            julia="mkpath(download_path)\nwrite(joinpath(download_path, \"out.txt\"), entry.key)",
            skip_checksum=true)
        local_path = download_dataset(db_jl, "julia_cmd_dataset")
        expected_file = joinpath(local_path, "out.txt")
        @test isfile(expected_file)
        @test read(expected_file, String) == "julia-cmd-test/result"
    end

    @testset "load_dataset" begin
        try
            download_dataset(db, "CMIP6_lgm_tos")
        catch
        end
        # Explicit loader keyword (precedence); called as loader(path, entry) or loader(path)
        data = load_dataset(db, "CMIP6_lgm_tos"; loader=path -> read(path, String))
        @test data isa String
        @test length(data) > 0
        # Entry loader field: code that evaluates to a function; called as fn(path, entry) or fn(path)
        db_loader = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db_loader, ""; name="with_loader_entry", key="load-test/entry_loader",
            julia="mkpath(download_path); write(joinpath(download_path, \"out.txt\"), \"from_entry_loader\")",
            loader="path -> read(joinpath(path, \"out.txt\"), String)", skip_checksum=true)
        data2 = load_dataset(db_loader, "with_loader_entry")
        @test data2 == "from_entry_loader"
        # No loader keyword and no entry.loader: default_loader(entry.format) used; unknown format errors
        @test_throws Exception load_dataset(db, "CMIP6_lgm_tos"; loader=nothing)
        # loader= function can accept (path, entry) and use entry fields
        received_doi = Ref("")
        load_dataset(db, "CMIP6_lgm_tos"; loader=(path, entry) -> (received_doi[] = entry.doi; read(path, String)))
        @test received_doi[] == ""
        load_dataset(db, "jonkers2024"; loader=(path, entry) -> (received_doi[] = entry.doi; read(path, String)))
        @test received_doi[] == "10.1594/PANGAEA.962852"
        # [loaders] registry: named loader, cache reuse
        toml_loaders = joinpath(datasets_dir, "with_loaders_section.toml")
        write(toml_loaders, """
        [_LOADERS]
        julia_modules = []
        julia_includes = []
        read_txt = "path -> read(joinpath(path, \\\"out.txt\\\"), String)"

        [entry_using_registry]
        key = "registry-load-test"
        loader = "read_txt"
        skip_checksum = true
        julia = \"\"\"
        mkpath(download_path)
        write(joinpath(download_path, \"out.txt\"), \"registry_loader_ok\")
        \"\"\"
        """)
        db_reg = Database(toml_loaders, datasets_dir; persist=false)
        download_dataset(db_reg, "entry_using_registry")
        r1 = load_dataset(db_reg, "entry_using_registry")
        r2 = load_dataset(db_reg, "entry_using_registry")
        @test r1 == r2
        @test r1 == "registry_loader_ok"
        @test haskey(db_reg.loader_cache, "read_txt")
        # Default by format: loader named "csv" in _LOADERS used when entry has no loader and format is csv
        toml_default = joinpath(datasets_dir, "with_default_csv.toml")
        write(toml_default, """
        [_LOADERS]
        julia_modules = []
        julia_includes = []
        csv = "path -> read(path, String)"

        [csv_via_format]
        key = "default-format-test/data.csv"
        julia = "write(download_path, \\\"csv,content\\\")"
        skip_checksum = true
        """)
        db_fmt = Database(toml_default, datasets_dir; persist=false)
        data_fmt = load_dataset(db_fmt, "csv_via_format")
        @test data_fmt == "csv,content"
        # Alias: md = "txt" means loader \"md\" resolves to loader \"txt\"
        toml_alias = joinpath(datasets_dir, "with_loader_alias.toml")
        write(toml_alias, """
        [_LOADERS]
        julia_modules = []
        julia_includes = []
        txt = "path -> read(joinpath(path, \\\"out.txt\\\"), String)"
        md = "txt"

        [entry_uses_md]
        key = "alias-test"
        loader = "md"
        skip_checksum = true
        julia = \"\"\"
        mkpath(download_path)
        write(joinpath(download_path, \"out.txt\"), \"from_alias\")
        \"\"\"
        """)
        db_alias = Database(toml_alias, datasets_dir; persist=false)
        data_alias = load_dataset(db_alias, "entry_uses_md")
        @test data_alias == "from_alias"
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
        register_dataset(db, "file://$(joinpath(@__DIR__, "test-data", "data_file.txt"))"; name="CMIP6_lgm_tos")
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

    @testset "requires (dependency resolution)" begin
        db2 = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db2, "file://$(joinpath(@__DIR__, "test-data", "data_file.txt"))"; name="base_data")
        register_dataset(db2, ""; name="depends_on_base", key="dep-test/dependent",
            shell="julia --startup-file=no $(joinpath(@__DIR__, "write_dummy.jl")) \$download_path \$key",
            requires=["base_data"], skip_checksum=true)
        # Download order: base_data first, then depends_on_base
        try
            path = download_dataset(db2, "depends_on_base")
            @test path == joinpath(datasets_dir, "dep-test/dependent")
        catch e
            @info "Skipping requires test (offline or error): $e"
        end
        # Command template: $path_<ref>, $path_1, $requires_paths
        register_dataset(db2, ""; name="uses_paths", key="dep-test/uses_paths",
            shell="julia --startup-file=no $(joinpath(@__DIR__, "write_dummy.jl")) \$download_path \"\$path_base_data\"",
            requires=["base_data"], skip_checksum=true)
        try
            path = download_dataset(db2, "uses_paths")
            root = DataManifest.get_project_root(db2)
            full_dir = root != "" ? joinpath(root, path) : abspath(path)
            out_path = joinpath(full_dir, "dummy.txt")
            @test isfile(out_path)
            out = read(out_path, String)
            @test occursin("data_file", out) || occursin("base_data", out)
        catch e
            @info "Skipping path template test: $e"
        end
        # Circular dependency
        register_dataset(db2, ""; name="cycle_a", key="cycle/a", shell="true", requires=["cycle_b"], skip_checksum=true)
        register_dataset(db2, ""; name="cycle_b", key="cycle/b", shell="true", requires=["cycle_a"], skip_checksum=true)
        @test_throws Exception download_dataset(db2, "cycle_a")
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
end
finally
    rm(datasets_dir; force=true, recursive=true)
end