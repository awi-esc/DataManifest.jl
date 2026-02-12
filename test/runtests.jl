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
    register_dataset(db, "file://$(abspath(joinpath(@__DIR__, "test-data", "data_file.txt")))"; name="CMIP6_lgm_tos", key="test-data/data_file.txt")
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

    @testset "julia: uri, key, doi etc. in scope (same as shell template)" begin
        # Regression: julia code must see uri, download_path, key, doi etc. (string interpolation like $uri)
        test_uri = "https://example.com/supplement.csv"
        test_doi = "10.1234/example"
        db_jl = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db_jl, test_uri; name="julia_vars_dataset", key="julia-vars/out", doi=test_doi,
            julia="write(download_path, \"uri=\$(uri)\npath=\$(download_path)\nkey=\$(key)\ndoi=\$(doi)\n\")",
            skip_checksum=true)
        out_path = download_dataset(db_jl, "julia_vars_dataset")
        content = read(out_path, String)
        @test occursin("uri=$(test_uri)", content)
        @test occursin("path=$(out_path)", content)
        @test occursin("key=julia-vars/out", content)
        @test occursin("doi=$(test_doi)", content)
    end

    @testset "julia: [_LOADERS].julia_modules applied to dataset julia code" begin
        # Regression: entry julia code must see modules from db.loaders_julia_modules (_LOADERS.julia_modules)
        # even when the entry has no julia_modules (e.g. LGMRecons.DataHelpers.create_input_dataframes).
        # Use stdlib Dates so we need no extra deps; without loaders_julia_modules, Dates would be undefined.
        db_jl = Database(datasets_folder=datasets_dir; persist=false)
        register_loaders(db_jl; julia_modules=["Dates"], persist=false)
        register_dataset(db_jl, ""; name="uses_loaders_mod", key="julia-modules-test/out",
            julia="write(download_path, \"loaded=\" * string(Dates.dayofweek(Dates.today())))",
            skip_checksum=true)
        out_path = download_dataset(db_jl, "uses_loaders_mod")
        content = read(out_path, String)
        @test startswith(content, "loaded=")
        @test parse(Int, content[8:end]) in 1:7
    end

    @testset "julia: [_LOADERS].julia_includes applied to loader context" begin
        # Loader code is evaluated in a module that has db.loaders_julia_includes run first.
        # So a loader can be the name of a function defined in an included file.
        helper_path = joinpath(datasets_dir, "julia_includes_helper.jl")
        write(helper_path, "included_loader(path) = read(joinpath(path, \"out.txt\"), String)\n")
        db_jl = Database(datasets_folder=datasets_dir; persist=false)
        register_loaders(db_jl; loaders=Dict("from_include" => "included_loader"), julia_includes=[helper_path], persist=false)
        register_dataset(db_jl, ""; name="uses_include_loader", key="julia-includes-test/out",
            loader="from_include",
            julia="mkpath(download_path); write(joinpath(download_path, \"out.txt\"), \"from_julia_includes\")",
            skip_checksum=true)
        out_path = download_dataset(db_jl, "uses_include_loader")
        @test isdir(out_path)
        data = load_dataset(db_jl, "uses_include_loader")
        @test data == "from_julia_includes"
    end

    @testset "load_dataset" begin
        try
            download_dataset(db, "CMIP6_lgm_tos")
        catch
        end
        # Explicit loader keyword (precedence); loader is called as loader(path)
        data = load_dataset(db, "CMIP6_lgm_tos"; loader=path -> read(path, String))
        @test data isa String
        @test length(data) > 0
        # Custom loader from entry.loader string (compiled on first use; invokelatest if world age)
        db_loader = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db_loader, ""; name="with_loader_entry", key="load-test/entry_loader",
            julia="mkpath(download_path); write(joinpath(download_path, \"out.txt\"), \"from_entry_loader\")",
            loader="path -> read(joinpath(path, \"out.txt\"), String)",
            skip_checksum=true)
        data2 = load_dataset(db_loader, "with_loader_entry")
        @test data2 == "from_entry_loader"
        # No loader keyword and no entry.loader: default_loader(entry.format) used (e.g. txt -> IO)
        io = load_dataset(db, "CMIP6_lgm_tos"; loader=nothing)
        @test io isa IO
        try
            @test read(io, String) isa String
        finally
            close(io)
        end
        # [_LOADERS] registry: entry.loader = "read_txt" uses named loader from TOML (invokelatest if world age)
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
        # loader= string: only allowed when it's a name defined in _LOADERS
        r3 = load_dataset(db_reg, "entry_using_registry"; loader="read_txt")
        @test r3 == "registry_loader_ok"
        @test_throws Exception load_dataset(db_reg, "entry_using_registry"; loader="nonexistent_loader")
        # Default by format: entry has no loader; _LOADERS.csv string is used (invokelatest if world age)
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
        # Built-in CSV default loader (no _LOADERS csv): must work and survive world-age (invokelatest used in _call_loader)
        db_builtin = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db_builtin, ""; name="csv_builtin", key="builtin-csv-load/data.csv", format="csv",
            julia="mkpath(dirname(download_path)); write(download_path, \"a,b\\n1,2\\n3,4\")",
            skip_checksum=true)
        data_builtin = load_dataset(db_builtin, "csv_builtin")
        @test size(data_builtin) == (2, 2)
        @test names(data_builtin) == ["a", "b"]
        @test data_builtin.a == [1, 3] && data_builtin.b == [2, 4]
        # Explicit loader="csv" resolves to built-in when not in _LOADERS
        data_builtin2 = load_dataset(db_builtin, "csv_builtin"; loader="csv")
        @test size(data_builtin2) == (2, 2) && data_builtin2.a == [1, 3]
        @test_throws Exception load_dataset(db_builtin, "csv_builtin"; loader="nonexistent_format")
        # Alias: md = "txt" in _LOADERS; entry.loader = "md" resolves to txt loader (invokelatest if world age)
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
        register_dataset(db, "file://$(abspath(joinpath(@__DIR__, "test-data", "data_file.txt")))"; name="CMIP6_lgm_tos", key="test-data/data_file.txt")
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
        register_dataset(db2, "file://$(abspath(joinpath(@__DIR__, "test-data", "data_file.txt")))"; name="base_data", key="test-data/data_file.txt")
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

    # Default loader tests must not skip when optional packages are missing; they must fail.
    @testset "DefaultLoaders" begin
        using DataManifest.DefaultLoaders: default_loader
        try
            using CSV, DataFrames, Parquet, NCDatasets, DimensionalData, JSON, YAML
            using Tar, CodecZlib, ZipFile
        catch e
            throw(ErrorException(
                "DefaultLoaders tests require test dependencies. Run: Pkg.test(\"DataManifest\") (recommended), or add the packages listed in Project.toml [extras] to your environment. Original error: " *
                sprint(showerror, e)))
        end
        loader_dir = mktempdir(prefix="DataManifest_loaders_"; cleanup=true)

        # toml (no extra dep)
        toml_path = joinpath(loader_dir, "x.toml")
        open(toml_path, "w") do io
            TOML.print(io, Dict("a" => 1, "b" => "two"))
        end
        data = default_loader("toml")(toml_path)
        @test data isa Dict
        @test data["a"] == 1
        @test data["b"] == "two"

        # txt / md (return IO)
        txt_path = joinpath(loader_dir, "x.txt")
        write(txt_path, "hello")
        io = default_loader("txt")(txt_path)
        @test io isa IO
        try
            @test read(io, String) == "hello"
        finally
            close(io)
        end
        md_path = joinpath(loader_dir, "x.md")
        write(md_path, "# title")
        io = default_loader("md")(md_path)
        @test io isa IO
        try
            @test read(io, String) == "# title"
        finally
            close(io)
        end

        # json (call loader; must fail if JSON not available)
        json_path = joinpath(loader_dir, "x.json")
        open(json_path, "w") do f
            JSON.print(f, Dict("k" => [1, 2]))
        end
        data_json = default_loader("json")(json_path)
        @test haskey(data_json, "k")
        @test data_json["k"] == [1, 2]

        # yaml (call loader; must fail if YAML not available)
        yaml_path = joinpath(loader_dir, "x.yml")
        write(yaml_path, "a: 1\nb: two")
        data_yaml = default_loader("yaml")(yaml_path)
        @test data_yaml isa Dict
        @test get(data_yaml, "a", get(data_yaml, :a, nothing)) == 1
        @test get(data_yaml, "b", get(data_yaml, :b, nothing)) == "two"

        # csv (call loader; must fail if CSV/DataFrames not available)
        csv_path = joinpath(loader_dir, "x.csv")
        DataFrame(a=[1, 2], b=[3, 4]) |> (df -> CSV.write(csv_path, df))
        data_csv = default_loader("csv")(csv_path)
        @test data_csv isa DataFrame
        @test size(data_csv) == (2, 2)
        @test data_csv.a == [1, 2]

        # parquet (call loader; must fail if Parquet/DataFrames not available)
        parquet_path = joinpath(loader_dir, "x.parquet")
        Parquet.write_parquet(parquet_path, DataFrame(x=[1, 2], y=[3, 4]))
        data_parquet = default_loader("parquet")(parquet_path)
        @test data_parquet isa DataFrame
        @test size(data_parquet) == (2, 2)

        # nc (call loader; must fail if NCDatasets not available)
        nc_path = joinpath(loader_dir, "x.nc")
        NCDatasets.NCDataset(nc_path, "c") do ds
            NCDatasets.defDim(ds, "n", 3)
            v = NCDatasets.defVar(ds, "vals", Float64, ("n",))
            v[:] = [1.0, 2.0, 3.0]
            ds.attrib["title"] = "test"
            v.attrib["units"] = "m"
        end
        ds_nc = default_loader("nc")(nc_path)
        try
            @test ds_nc["vals"][:] == [1.0, 2.0, 3.0]
            @test ds_nc.attrib["title"] == "test"
            @test ds_nc["vals"].attrib["units"] == "m"
        finally
            close(ds_nc)
        end

        # dimstack (call loader; must fail if NCDatasets/DimensionalData not available)
        @test default_loader("dimstack") isa Function
        # Loader returns DimStack; content checked via NCDatasets (dimstack loader has format-specific API)
        NCDatasets.NCDataset(nc_path) do ds
            @test haskey(ds, "vals")
            @test ds.attrib["title"] == "test"
            @test ds["vals"].attrib["units"] == "m"
        end
        # Round-trip: array + variable attributes -> NetCDF -> dimstack loader (experimental module; no _global layer)
        stack = default_loader("dimstack")(nc_path)
        @test stack isa DimensionalData.DimStack
        @test parent(stack[:vals]) == [1.0, 2.0, 3.0]
        @test stack[:vals].metadata[:units] == "m"

        # 3-D NetCDF (like LeGrande–Schmidt: lon × lat × depth) to exercise dimstack dimension handling
        nc_3d_path = joinpath(loader_dir, "data_3d.nc")
        NCDatasets.NCDataset(nc_3d_path, "c") do ds
            NCDatasets.defDim(ds, "lon", 3)
            NCDatasets.defDim(ds, "lat", 4)
            NCDatasets.defDim(ds, "depth", 5)
            v = NCDatasets.defVar(ds, "d18o", Float32, ("lon", "lat", "depth"))
            v[:] = reshape(Float32(1):Float32(60), 3, 4, 5)
            v.attrib["units"] = "permil"
            ds.attrib["title"] = "3D test"
        end
        stack_3d = default_loader("dimstack")(nc_3d_path)
        @test stack_3d isa DimensionalData.DimStack
        @test size(stack_3d[:d18o]) == (3, 4, 5)
        @test stack_3d[:d18o].metadata[:units] == "permil"
        @test parent(stack_3d[:d18o])[1, 1, 1] == 1.0f0
        @test parent(stack_3d[:d18o])[3, 4, 5] == 60.0f0

        # Optional: exercise dimstack on a real 3D NetCDF (e.g. LeGrande–Schmidt) when path is set
        real_nc = get(ENV, "DATAMANIFEST_DIMSTACK_NC", "")
        if real_nc != ""
            path_nc = split(real_nc, '#'; limit=2)[1]
            if isfile(path_nc)
                stack_real = default_loader("dimstack")(real_nc)
                @test stack_real isa DimensionalData.DimStack
                @test haskey(stack_real, :d18o)
                @test size(stack_real[:d18o]) == (360, 180, 33)
              else
                @warn "DATAMANIFEST_DIMSTACK_NC set but file not found: $path_nc"
            end
        end

        # zip (call loader; returns path to extracted dir; must fail if ZipFile not available)
        zip_path = joinpath(loader_dir, "x.zip")
        w = ZipFile.Writer(zip_path)
        f = ZipFile.addfile(w, "a.txt"; method=ZipFile.Deflate)
        write(f, "zip content")
        close(w)
        zip_out = default_loader("zip")(zip_path)
        @test zip_out isa String
        @test isdir(zip_out)
        @test read(joinpath(zip_out, "a.txt"), String) == "zip content"

        # tar (call loader; returns path to extracted dir; must fail if Tar not available)
        tar_dir = mktempdir(prefix="DataManifest_tar_src_"; cleanup=true)
        write(joinpath(tar_dir, "b.txt"), "tar content")
        tar_path = joinpath(loader_dir, "x.tar")
        Tar.create(tar_dir, tar_path)
        tar_out = default_loader("tar")(tar_path)
        @test tar_out isa String
        @test isdir(tar_out)
        @test read(joinpath(tar_out, "b.txt"), String) == "tar content"

        # tar.gz (call loader; returns path to extracted dir; must fail if Tar/CodecZlib not available)
        tar_gz_path = joinpath(loader_dir, "x.tar.gz")
        open(tar_path) do io
            open(tar_gz_path, "w") do gz
                write(gz, transcode(CodecZlib.GzipCompressor, read(io)))
            end
        end
        tar_gz_out = default_loader("tar.gz")(tar_gz_path)
        @test tar_gz_out isa String
        @test isdir(tar_gz_out)
        @test read(joinpath(tar_gz_out, "b.txt"), String) == "tar content"

        rm(loader_dir; force=true, recursive=true)
    end

    @testset "validate_loaders" begin
        # Empty loaders: validate_loaders completes without error (no external TOML/modules loaded)
        val_dir = mktempdir(prefix="DataManifest_validate_"; cleanup=true)
        db_empty = Database(datasets_folder=val_dir, persist=false)
        @test length(db_empty.loaders) == 0
        validate_loaders(db_empty)

        # One inline loader: validate_loaders compiles it; validate_loader returns the function
        register_loaders(db_empty; loaders=Dict("raw" => "path -> read(path, String)"), persist=false)
        validate_loaders(db_empty)
        fn = validate_loader(db_empty, "raw")
        @test fn isa Function
        tmp = joinpath(mktempdir(), "t.txt")
        write(tmp, "hello")
        @test fn(tmp) == "hello"
        rm(tmp; force=true)
    end
end
finally
    rm(datasets_dir; force=true, recursive=true)
end