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

# ----- conformance helpers (used by the conformance testset below) -----

# A binding's ref: the bare string, or a `{ ref … }` table's `ref` ("" otherwise).
_conf_binding_ref(b) = b isa AbstractString ? String(b) :
    (b isa AbstractDict && get(b, "ref", "") isa AbstractString ? String(get(b, "ref", "")) : "")

# spec-v3.5: the dataset's shell command — bare `shell` field, else legacy `[_LANG.shell].fetcher`.
function _conf_shell_fetcher(entry::DatasetEntry)::String
    entry.shell != "" && return entry.shell
    lang = get(entry.extra, "_LANG", nothing)
    lang isa AbstractDict || return ""
    shell = get(lang, "shell", nothing)
    shell isa AbstractDict || return ""
    f = get(shell, "fetcher", nothing)
    f isa AbstractString ? String(f) : ""
end

# spec-v3.4: the bare (language-implicit) fetcher ref, or "".
_conf_bare_fetcher(entry::DatasetEntry)::String = _conf_binding_ref(get(entry.extra, "fetcher", nothing))

function _conf_infer_fetcher(db::Database, entry::DatasetEntry)
    # rung 1: explicit own fetcher, else bare (language-implicit) fetcher.
    entry.lang_julia_fetcher != "" && return ("own-fetcher", entry.lang_julia_fetcher)
    bf = _conf_bare_fetcher(entry)
    bf != "" && return ("own-fetcher", bf)
    sf = _conf_shell_fetcher(entry)
    sf != "" && return ("shell", sf)
    (entry.uri != "" || !isempty(entry.uris)) && return ("uri", nothing)
    return nothing
end

function _conf_infer_loader(db::Database, entry::DatasetEntry)
    # rung 1: explicit own loader, else bare (language-implicit) loader.
    entry.lang_julia_loader != "" && return ("per-dataset", entry.lang_julia_loader)
    entry.loader != "" && return ("per-dataset", entry.loader)
    fmt = lowercase(strip(entry.format))
    if !isempty(fmt)
        # rung 2: `[_LANG.julia.loaders][fmt]`, else `[_LOADERS][fmt]` (language-implicit).
        for (k, b) in pairs(db.lang_julia_loaders)
            lowercase(strip(k)) == fmt && return ("manifest-format-default", _conf_binding_ref(b))
        end
        for (k, b) in pairs(db.loaders)
            lowercase(strip(k)) == fmt && return ("manifest-format-default", _conf_binding_ref(b))
        end
    end
    return ("builtin", nothing)
end

datasets_dir = mktempdir(prefix="DataManifest_test_"; cleanup=true)

# Isolate the spec-v5 user-global config (~/.config/datamanifest/config.toml) so a
# developer's real config never leaks into resolution during tests.
ENV["XDG_CONFIG_HOME"] = mktempdir(prefix="DataManifest_xdgconfig_"; cleanup=true)

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

    @testset "Manifest filename discovery" begin
        C = DataManifest.Config
        # Cross-tool rule: discovery order is datamanifest.toml > DataManifest.toml
        # > datasets.toml > Datasets.toml; a new manifest is created under the
        # first (canonical) name.
        @test C.MANIFEST_FILENAMES ==
            ["datamanifest.toml", "DataManifest.toml", "datasets.toml", "Datasets.toml"]

        touch_names(d, names...) = foreach(n -> touch(joinpath(d, n)), names)

        # A new project (no manifest yet) defaults to the canonical name.
        d = mktempdir()
        @test C.default_toml_in(d) == joinpath(d, "datamanifest.toml")

        # Existing projects keep working: a lone Datasets.toml is still discovered.
        d = mktempdir(); touch_names(d, "Datasets.toml")
        @test C.default_toml_in(d) == joinpath(d, "Datasets.toml")

        # datasets.toml beats Datasets.toml.
        d = mktempdir(); touch_names(d, "Datasets.toml", "datasets.toml")
        @test C.default_toml_in(d) == joinpath(d, "datasets.toml")

        # DataManifest.toml beats datasets.toml.
        d = mktempdir(); touch_names(d, "Datasets.toml", "datasets.toml", "DataManifest.toml")
        @test C.default_toml_in(d) == joinpath(d, "DataManifest.toml")

        # datamanifest.toml beats everything.
        d = mktempdir()
        touch_names(d, "Datasets.toml", "datasets.toml", "DataManifest.toml", "datamanifest.toml")
        @test C.default_toml_in(d) == joinpath(d, "datamanifest.toml")
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

        # canonical=true routes through the Python `datamanifest format` CLI when
        # present, else falls back to native output (semantically identical). The
        # cross-tool byte-identity itself is checked by datamanifest.toml's
        # tests/byte_identity.sh; here we just assert the option round-trips.
        canon_toml = joinpath(datasets_dir, "test_canonical.toml")
        write(db, canon_toml; canonical=true)
        @test isfile(canon_toml)
        @test read_dataset(canon_toml, datasets_dir; persist=false) == db

        # Native key order matches the Python tool: structural `_*` tables
        # first, then datasets, both alphabetical. A plain code-point sort
        # would drop `_META` between upper- and lower-cased dataset names.
        db_ord = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db_ord, "https://example.com/z.csv"; name="ZZZ",
            skip_checksum=true, persist=false)
        register_dataset(db_ord, "https://example.com/a.csv"; name="aaa",
            skip_checksum=true, persist=false)
        db_ord.extra["_META"] = Dict{String,Any}("schema" => 1)
        ord_toml = joinpath(datasets_dir, "test_order.toml")
        write(db_ord, ord_toml)
        headers = [m.captures[1] for m in eachmatch(r"^\[([^\]]+)\]"m, read(ord_toml, String))]
        @test headers == ["_META", "ZZZ", "aaa"]

        # DATAMANIFEST_CANONICAL=1 opts in to the canonical pipe (the ladder is
        # frozen at materialization, so the Database is built under the env it
        # should see); when the Python CLI is absent it falls back to native
        # output, so the write must succeed and round-trip either way.
        env_toml = joinpath(datasets_dir, "test_canonical_env.toml")
        withenv("DATAMANIFEST_CANONICAL" => "1") do
            db_env = read_dataset(test_toml, datasets_dir; persist=false)
            write(db_env, env_toml)
            @test read_dataset(env_toml, datasets_dir; persist=false) == db_env
        end
    end

    @testset "canonical directive (config ladder + worktree routing)" begin
        ST = DataManifest.Storage

        # Ladder unit: TOML booleans and truthy strings; _HOST glob beats the
        # base value within a layer; env beats every layer.
        layers = [Dict{String,Any}("canonical" => false,
                      "_HOST" => Dict{String,Any}("h*" => Dict{String,Any}("canonical" => true)))]
        @test ST.canonical_write(storage_config=layers, env=Dict(), host="hpc1")
        @test !ST.canonical_write(storage_config=layers, env=Dict(), host="other")
        @test ST.canonical_write(storage_config=[Dict{String,Any}("canonical" => "yes")], env=Dict(), host="x")
        @test !ST.canonical_write(storage_config=[Dict{String,Any}("canonical" => "off")], env=Dict(), host="x")
        @test !ST.canonical_write(storage_config=Dict{String,Any}(), env=Dict(), host="x")
        @test !ST.canonical_write(storage_config=layers,
            env=Dict("DATAMANIFEST_CANONICAL" => "0"), host="hpc1")

        # A ConfigSnapshot is authoritative: its captured env/host replace
        # the resolver inputs (a passed env/host is ignored) — another context
        # gets its own snapshot instead.
        snap = ST.ConfigSnapshot([Dict{String,Any}()],
            Dict("DATAMANIFEST_CANONICAL" => "1"), "h")
        @test ST.canonical_write(storage_config=snap)
        @test ST.canonical_write(storage_config=snap, env=Dict())
        @test ST.canonical_write(storage_config=snap, host="other")

        # A fake `datamanifest` CLI that marks its output, so the tests can tell
        # the canonical pipe ran without needing the real Python tool.
        make_fake_cli(dir) = begin
            bin = joinpath(dir, ".venv", "bin")
            mkpath(bin)
            exe = joinpath(bin, "datamanifest")
            Base.write(exe, "#!/bin/sh\necho '# formatted-by-fake'\ncat\n")
            chmod(exe, 0o755)
            exe
        end
        # The snapshot freezes at materialization, anchored at the manifest
        # path — so the Database must know its manifest (and be constructed
        # under the env it should see).
        new_db(folder, toml) = begin
            isfile(toml) && rm(toml)  # fresh manifest each time; write() recreates it
            d = Database(datasets_toml=toml, datasets_folder=folder)
            register_dataset(d, "https://example.com/a.csv"; name="a",
                skip_checksum=true, persist=false)
            d
        end

        # `canonical = true` in the checkout config (.datamanifest/config.toml)
        # turns the pipe on; the CLI is found in the project-local .venv.
        proj = mktempdir(); xdg = mktempdir()  # isolate the user-global config
        make_fake_cli(proj)
        mkpath(joinpath(proj, ".datamanifest"))
        Base.write(joinpath(proj, ".datamanifest", "config.toml"), "canonical = true\n")
        withenv("DATAMANIFEST_CANONICAL" => nothing, "XDG_CONFIG_HOME" => xdg) do
            target = joinpath(proj, "Datasets.toml")
            write(new_db(mktempdir(), target), target)
            @test startswith(read(target, String), "# formatted-by-fake")

            # The environment beats the config layers: =0 forces native output.
            withenv("DATAMANIFEST_CANONICAL" => "0") do
                write(new_db(mktempdir(), target), target)
                @test !startswith(read(target, String), "# formatted-by-fake")
            end
        end

        # The snapshot is FROZEN at materialization: config-file edits and env
        # changes after the Database is built do not apply to it;
        # freeze_config! re-reads both.
        proj2 = mktempdir()
        make_fake_cli(proj2)
        target2 = joinpath(proj2, "Datasets.toml")
        db2 = withenv("DATAMANIFEST_CANONICAL" => nothing, "XDG_CONFIG_HOME" => xdg) do
            new_db(mktempdir(), target2)
        end
        mkpath(joinpath(proj2, ".datamanifest"))
        Base.write(joinpath(proj2, ".datamanifest", "config.toml"), "canonical = true\n")
        withenv("DATAMANIFEST_CANONICAL" => "1", "XDG_CONFIG_HOME" => xdg) do
            write(db2, target2)
            @test !startswith(read(target2, String), "# formatted-by-fake")
            freeze_config!(db2)
            write(db2, target2)
            @test startswith(read(target2, String), "# formatted-by-fake")
        end

        # A linked git worktree starts without the project's .datamanifest/ and
        # .venv: both the checkout-config lookup and the CLI lookup fall through
        # to the corresponding paths in the main checkout.
        repo = mktempdir()
        run(`git -C $repo init -q -b main`)
        run(`git -C $repo -c user.email=t@t -c user.name=t commit -q --allow-empty -m init`)
        make_fake_cli(repo)
        mkpath(joinpath(repo, ".datamanifest"))
        Base.write(joinpath(repo, ".datamanifest", "config.toml"), "canonical = true\n")
        wt = joinpath(repo, "wt")
        run(`git -C $repo worktree add -q $wt`)
        withenv("DATAMANIFEST_CANONICAL" => nothing, "XDG_CONFIG_HOME" => xdg,
                "PATH" => "/usr/bin:/bin") do
            target = joinpath(wt, "Datasets.toml")
            write(new_db(mktempdir(), target), target)
            @test startswith(read(target, String), "# formatted-by-fake")
        end
        # A config file present in the worktree itself wins over the main checkout's.
        mkpath(joinpath(wt, ".datamanifest"))
        Base.write(joinpath(wt, ".datamanifest", "config.toml"), "canonical = false\n")
        withenv("DATAMANIFEST_CANONICAL" => nothing, "XDG_CONFIG_HOME" => xdg,
                "PATH" => "/usr/bin:/bin") do
            target = joinpath(wt, "Datasets.toml")
            write(new_db(mktempdir(), target), target)
            @test !startswith(read(target, String), "# formatted-by-fake")
        end
    end

    @testset "read pools (datasets_pools)" begin
        DB = DataManifest.Databases
        pooldir = mktempdir()
        mkpath(joinpath(pooldir, "host")); write(joinpath(pooldir, "host", "f.txt"), "pooled")

        # An explicit pool: a dataset already present at <pool>/<key> is reused in place.
        dbp = Database(datasets_folder=mktempdir(), persist=false)
        dbp.storage_config = Dict{String,Any}("datasets_pools" => [pooldir])
        register_dataset(dbp, "https://example.com/host/f.txt"; name="d",
            key="host/f.txt", skip_checksum=true, persist=false)
        @test DB.resolve_from_pools(dbp, dbp.datasets["d"]) == joinpath(pooldir, "host", "f.txt")

        # An explicit EMPTY list disables pools.
        dbp.storage_config = Dict{String,Any}("datasets_pools" => String[])
        @test DB.resolve_from_pools(dbp, dbp.datasets["d"]) == ""

        # sha256 verification: a pooled copy whose digest mismatches is skipped, not adopted.
        dbp.storage_config = Dict{String,Any}("datasets_pools" => [pooldir])
        dbp.datasets["d"].sha256 = "0"^64
        dbp.datasets["d"].skip_checksum = false
        @test DB.resolve_from_pools(dbp, dbp.datasets["d"]) == ""

        # Built-in default pool: `~/.cache/Datasets` is probed when `datasets_pools` is unset.
        home = mktempdir(); mkpath(joinpath(home, ".cache", "Datasets", "host"))
        write(joinpath(home, ".cache", "Datasets", "host", "g.txt"), "y")
        withenv("HOME" => home) do
            dbp2 = Database(datasets_folder=mktempdir(), persist=false)
            register_dataset(dbp2, "https://example.com/host/g.txt"; name="g",
                key="host/g.txt", skip_checksum=true, persist=false)
            @test DB.resolve_from_pools(dbp2, dbp2.datasets["g"]) ==
                  joinpath(home, ".cache", "Datasets", "host", "g.txt")
        end

        # An extract=true dataset is reused from a pool holding the EXTRACTED dir
        # (<pool>/<extract_path>), not just the archive (Python-parity fix).
        epool = mktempdir()
        ek = DataManifest.Config.get_extract_path("host.com/data/archive.zip")
        mkpath(joinpath(epool, ek)); write(joinpath(epool, ek, "inner.txt"), "x")
        dbe = Database(datasets_folder=mktempdir(), persist=false)
        dbe.storage_config = Dict{String,Any}("datasets_pools" => [epool])
        register_dataset(dbe, "https://host.com/data/archive.zip"; name="arc",
            key="host.com/data/archive.zip", extract=true, skip_checksum=true, persist=false)
        @test dbe.datasets["arc"].extract
        @test DB.resolve_from_pools(dbe, dbe.datasets["arc"]) == joinpath(epool, ek)

        # datacache_pools is opt-in: undefined ⇒ none; an explicit list resolves.
        @test isempty(DataManifest.Storage.datacache_pools())
        @test DataManifest.Storage.datacache_pools(;
                  storage_config=Dict{String,Any}("datacache_pools" => [pooldir])) == [pooldir]
    end

    @testset "spec-v4.3 lazy_access + identifier resolution" begin
        DB = DataManifest.Databases
        d = mktempdir()
        toml = joinpath(d, "datasets.toml")

        # lazy_access: the path IS the uri; load opens it in place via a loader; no download,
        # nothing materialized, no state record.
        write(toml, """
        [_META]
        schema = 1
        [remote]
        uri = "s3://bucket/data.bin"
        lazy_access = true
        """)
        dbl = read_dataset(toml, joinpath(d, "store"); persist=false)
        e = dbl.datasets["remote"]
        @test e.lazy_access
        @test DB.get_dataset_path(dbl, e) == "s3://bucket/data.bin"
        @test download_dataset(dbl, "remote") == "s3://bucket/data.bin"   # not downloaded
        @test !isdir(joinpath(d, "store"))                                # nothing materialized
        @test load_dataset(dbl, "remote"; loader = p -> "open:" * string(p)) ==
              "open:s3://bucket/data.bin"
        # A bare lazy_access (no loader) is a fail-loud error.
        @test_throws ErrorException load_dataset(dbl, "remote")
        # lazy_access round-trips on write.
        out = joinpath(d, "out.toml"); write(dbl, out)
        @test occursin("lazy_access = true", read(out, String))
        @test read_dataset(out, d; persist=false).datasets["remote"].lazy_access

        # Object-store download (non-lazy) errors clearly — no native backend, never a silent skip.
        write(toml, "[_META]\nschema = 1\n[obj]\nuri = \"gs://b/x.nc\"\n")
        dbo = read_dataset(toml, joinpath(d, "store2"); persist=false)
        @test_throws ErrorException download_dataset(dbo, "obj")

        # Exact-or-error identifier resolution: an alias shared by two datasets is fail-loud.
        write(toml, """
        [_META]
        schema = 1
        [a]
        uri = "https://x/a.csv"
        aliases = ["shared"]
        [b]
        uri = "https://x/b.csv"
        aliases = ["shared"]
        """)
        dba = read_dataset(toml, joinpath(d, "store3"); persist=false)
        @test DB.search_dataset(dba, "a")[1] == "a"                    # exact name resolves
        @test_throws ErrorException DB.search_dataset(dba, "shared")   # ambiguous alias errors
    end

    @testset "spec-v5 two-folder storage" begin
        S = DataManifest.Storage
        env = Dict("XDG_DATA_HOME" => "/d", "XDG_CACHE_HOME" => "/c")

        # The two folders default to machine-global locations: one shared keyed store for
        # fetched datasets, a per-project ($project) produced cache.
        @test S.datasets_dir(; project_root="/r/myproj", env=env) ==
              "/d/datamanifest/shared/datasets"
        @test S.datacache_dir(; project_root="/r/myproj", env=env) ==
              "/c/datamanifest/projects/myproj/cached"
        # $project defaults to the project-root basename; a `project` field overrides it.
        @test S.resolve_symbol("project"; project_root="/r/myproj") == "myproj"
        @test S.datacache_dir(; project_root="/r/myproj", env=env,
                              storage_config=Dict{String,Any}("project" => "renamed")) ==
              "/c/datamanifest/projects/renamed/cached"
        # Relative values restore the pre-v5 repo-local layout.
        sc_local = Dict{String,Any}("datasets_dir" => "datasets", "datacache_dir" => "cached")
        @test S.datasets_dir(; project_root="/r", storage_config=sc_local, env=env) == "/r/datasets"
        @test S.datacache_dir(; project_root="/r", storage_config=sc_local, env=env) == "/r/cached"
        # Env-var overrides (DATAMANIFEST_<FIELD>) win.
        envd = merge(env, Dict("DATAMANIFEST_DATASETS_DIR" => "/abs/data",
                               "DATAMANIFEST_DATACACHE_DIR" => "/abs/cache"))
        @test S.datasets_dir(; project_root="/r", env=envd) == "/abs/data"
        @test S.datacache_dir(; project_root="/r", env=envd) == "/abs/cache"
        # `[_STORAGE]` overrides: a path expression (here a $-symbol) is expanded.
        sc = Dict{String,Any}("datasets_dir" => "\$user_data_dir/proj",
                              "datacache_dir" => "\$user_cache_dir/proj")
        @test S.datasets_dir(; project_root="/r", storage_config=sc, env=env) == "/d/proj"
        @test S.datacache_dir(; project_root="/r", storage_config=sc, env=env) == "/c/proj"

        # $user_data_dir / $user_cache_dir are BARE platformdirs (no app segment).
        @test S.user_data_dir(env) == "/d"
        @test S.user_cache_dir(env) == "/c"
        @test S.expand_path_expr("\$user_data_dir/x"; env=env) == "/d/x"

        # dataset_storage_path: default keyed location is `$datasets_dir/$key`.
        @test S.dataset_storage_path("", "host/f.nc"; project_root="/r", env=env) ==
              "/d/datamanifest/shared/datasets/host/f.nc"
        @test S.dataset_storage_path("", "host/f.nc"; project_root="/r",
                                     storage_config=sc_local, env=env) ==
              "/r/datasets/host/f.nc"
        # A `$scratch/$key` override is tool-managed keyed (uses a user symbol).
        scu = Dict{String,Any}("scratch" => "/scratch/me")
        @test S.dataset_storage_path("\$scratch/\$key", "a/b.nc";
                                     project_root="/r", storage_config=scu, env=env) ==
              "/scratch/me/a/b.nc"
        # An exact path (no `$key`) is user-managed and used verbatim.
        @test S.dataset_storage_path("\$scratch/exact/file.nc", "ignored";
                                     project_root="/r", storage_config=scu, env=env) ==
              "/scratch/me/exact/file.nc"
        # A relative exact path resolves against the project root.
        @test S.dataset_storage_path("data/in_repo.nc", "ignored"; project_root="/r", env=env) ==
              "/r/data/in_repo.nc"

        # user_symbols: bare [_STORAGE] keys excluding the reserved fields.
        @test S.user_symbols(Dict{String,Any}("scratch" => "/s", "datasets_dir" => "x",
                                              "datacache_dir" => "y",
                                              "_HOST" => Dict{String,Any}())) == ["scratch"]

        # Per-dataset storage_path round-trips: keyed, exact, and omitted (stays "").
        mktempdir() do dd
            toml = joinpath(dd, "datasets.toml")
            write(toml, """
            [_META]
            schema = 1
            [a]
            uri = "https://x/a.nc"
            format = "nc"
            storage_path = "\$scratch/\$key"
            [b]
            uri = "https://x/b.nc"
            format = "nc"
            storage_path = "/data/exact/b.nc"
            [c]
            uri = "https://x/c.nc"
            format = "nc"
            """)
            db_v4 = read_dataset(toml, dd; persist=false)
            @test db_v4.datasets["a"].storage_path == "\$scratch/\$key"
            @test db_v4.datasets["b"].storage_path == "/data/exact/b.nc"
            @test db_v4.datasets["c"].storage_path == ""   # omitted -> keyed default
            out_v4 = joinpath(dd, "out.toml"); write(db_v4, out_v4)
            txt_v4 = read(out_v4, String)
            @test occursin("storage_path = \"\$scratch/\$key\"", txt_v4)
            @test occursin("storage_path = \"/data/exact/b.nc\"", txt_v4)
            db_v4b = read_dataset(out_v4, dd; persist=false)
            @test db_v4b.datasets["a"].storage_path == "\$scratch/\$key"
            @test db_v4b.datasets["b"].storage_path == "/data/exact/b.nc"
            @test db_v4b.datasets["c"].storage_path == ""
        end
    end

    @testset "spec-v5 scoped config files + ladder + state relocation" begin
        S = DataManifest.Storage
        C = DataManifest.Cache
        env = Dict("XDG_DATA_HOME" => "/d", "XDG_CACHE_HOME" => "/c")

        mktempdir() do root
            # Layer files: checkout config overrides the manifest; user config only fills in.
            mkpath(joinpath(root, ".datamanifest"))
            write(joinpath(root, ".datamanifest", "config.toml"), """
            datasets_dir = "\$user_data_dir/from-local"
            [_HOST."*"]
            scratch = "/local-scratch"
            """)
            userdir = mktempdir()
            mkpath(joinpath(userdir, "datamanifest"))
            write(joinpath(userdir, "datamanifest", "config.toml"), """
            datacache_dir = "\$user_cache_dir/from-user"
            project = "user-named"
            """)
            envc = merge(env, Dict("XDG_CONFIG_HOME" => userdir))
            manifest_sc = Dict{String,Any}("datacache_dir" => "cached", "scratch" => "/mani-scratch")

            layers = S.config_layers(manifest_sc; project_root=root, env=envc)
            @test length(layers) == 3
            # checkout config (rung 2) beats the manifest (rung 4):
            @test S.datasets_dir(; project_root=root, storage_config=layers, env=envc) ==
                  "/d/from-local"
            # ...including its _HOST section (rung 2 host beats manifest base).
            @test S.resolve_symbol("scratch"; project_root=root, storage_config=layers, env=envc) ==
                  "/local-scratch"
            # the manifest (rung 4) beats the user config (rung 5):
            @test S.datacache_dir(; project_root=root, storage_config=layers, env=envc) ==
                  joinpath(root, "cached")
            # the user config fills in what nothing above sets ($project here):
            @test S.resolve_symbol("project"; project_root=root, storage_config=layers, env=envc) ==
                  "user-named"
            # env (rung 1) beats everything:
            enve = merge(envc, Dict("DATAMANIFEST_DATASETS_DIR" => "/abs/override"))
            @test S.datasets_dir(; project_root=root, storage_config=layers, env=enve) ==
                  "/abs/override"
        end

        # POOL_DEFAULTS (spec-v5): $repo/datasets first (skipped without a project root),
        # then the shared store, then the legacy locations.
        @test S.POOL_DEFAULTS == ("\$repo/datasets",
                                  "\$user_data_dir/datamanifest/shared/datasets",
                                  "\$user_data_dir/datamanifest/datasets",
                                  "~/.cache/Datasets")
        pools_r = S.datasets_pools(; project_root="/r", env=env)
        @test pools_r[1] == "/r/datasets"
        @test pools_r[2] == "/d/datamanifest/shared/datasets"
        # Without a project root the $repo/datasets default is skipped entirely.
        @test S.datasets_pools(; env=env)[1] == "/d/datamanifest/shared/datasets"

        # State file: canonical .datamanifest/state.toml; a legacy sibling
        # .datamanifest-state.toml is read and RELOCATED on first write; the
        # .datamanifest/ dir self-ignores.
        mktempdir() do dir
            legacy = joinpath(dir, ".datamanifest-state.toml")
            write(legacy, """
            [_META]
            schema = 5
            [datasets."ex.com/foo.nc"]
            storage_path = "datasets/ex.com/foo.nc"
            sha256 = "abc"
            """)
            @test C.locate_state(dir) == legacy
            idx = read_index_or_empty(dir)
            @test DataManifest.Cache.dataset_path_of(idx, "ex.com/foo.nc") ==
                  "datasets/ex.com/foo.nc"
            target = write_index(idx)
            @test target == joinpath(dir, ".datamanifest", "state.toml")
            @test isfile(target)
            @test !isfile(legacy)                      # first write relocates
            @test strip(read(joinpath(dir, ".datamanifest", ".gitignore"), String)) == "*"
            @test C.locate_state(dir) == target
        end
    end

    @testset "git worktree shared state file" begin
        C = DataManifest.Cache
        gitok = try success(pipeline(`git --version`; stdout=devnull, stderr=devnull))
        catch; false end
        if !gitok
            @warn "git not available, skipping worktree state-file tests"
        else
            mktempdir() do tmp
                git(args...) = run(pipeline(`git $(collect(args))`;
                                            stdout=devnull, stderr=devnull))
                main = joinpath(tmp, "main")
                mkpath(joinpath(main, "sub"))
                write(joinpath(main, "README"), "x\n")
                write(joinpath(main, "sub", "file"), "x\n")
                git("-C", main, "init", "-q")
                git("-C", main, "add", "-A")
                git("-C", main, "-c", "user.name=t", "-c", "user.email=t@t",
                    "commit", "-q", "-m", "init")
                wt = joinpath(tmp, "wt")
                git("-C", main, "worktree", "add", "-q", wt)

                # The main checkout is never redirected; the worktree maps onto it
                # (subdirectories included).
                @test C._main_checkout_dir(main) == ""
                @test realpath(C._main_checkout_dir(wt)) == realpath(main)
                @test realpath(C._main_checkout_dir(joinpath(wt, "sub"))) ==
                      realpath(joinpath(main, "sub"))

                # No state file anywhere: lookups in the worktree bind to the MAIN
                # checkout's canonical path, so the first write lands in the shared
                # inventory.
                main_state = joinpath(C._main_checkout_dir(wt), C.STATE_FILE_NAME)
                @test C.locate_state(wt) == main_state
                idx = read_index_or_empty(wt)
                @test idx.path == main_state
                target = write_index(idx)
                @test realpath(target) == realpath(joinpath(main, C.STATE_FILE_NAME))
                @test !ispath(joinpath(wt, ".datamanifest"))

                # The shared inventory is read back from the worktree.
                write(joinpath(main, ".datamanifest", "state.toml"), """
                [_META]
                schema = 5
                [datasets."ex.com/foo.nc"]
                storage_path = "datasets/ex.com/foo.nc"
                sha256 = "abc"
                """)
                idx = read_index_or_empty(wt)
                @test C.dataset_path_of(idx, "ex.com/foo.nc") == "datasets/ex.com/foo.nc"

                # A state file in the worktree itself always wins.
                mkpath(joinpath(wt, ".datamanifest"))
                local_state = joinpath(wt, ".datamanifest", "state.toml")
                write(local_state, "[_META]\nschema = 5\n")
                @test C.locate_state(wt) == local_state
            end
        end
    end

    @testset "description roundtrip" begin
        db_d = Database(datasets_folder=datasets_dir; persist=false)
        descr = "Coretop-paired d18oc reference (Malevich 2019), reformatted to the Tierney LH schema."
        register_dataset(db_d, ""; name="with_desc",
            key="description-test/out.csv",
            julia="write(download_path, \"x\")",
            skip_checksum=true, description=descr)
        @test db_d.datasets["with_desc"].description == descr
        # serialised entry contains the description key with the full text
        d = DataManifest.Databases.to_dict(db_d.datasets["with_desc"])
        @test get(d, "description", "") == descr
        # roundtrip through TOML preserves description and equality
        toml_path = joinpath(datasets_dir, "with_description.toml")
        write(db_d, toml_path)
        reloaded = read_dataset(toml_path, datasets_dir; persist=false)
        @test reloaded.datasets["with_desc"].description == descr
        @test reloaded == db_d
        # empty description is omitted from the serialised dict
        register_dataset(db_d, ""; name="no_desc",
            key="description-test/none.csv",
            julia="write(download_path, \"x\")",
            skip_checksum=true)
        @test !haskey(DataManifest.Databases.to_dict(db_d.datasets["no_desc"]), "description")
    end

    @testset "uris (multiple URIs for one entry)" begin
        # Register via Julia API with uris keyword
        db_u = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db_u, ""; name="multi_file", key="uris-test/folder",
            uris=["file://$(abspath(joinpath(@__DIR__, "test-data", "data_file.txt")))"],
            skip_checksum=true)
        @test haskey(db_u.datasets, "multi_file")
        @test db_u.datasets["multi_file"].uris == ["file://$(abspath(joinpath(@__DIR__, "test-data", "data_file.txt")))"]
        @test db_u.datasets["multi_file"].key == "uris-test/folder"

        # uri as a list is equivalent to uris
        db_u2 = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db_u2, ["file://$(abspath(joinpath(@__DIR__, "test-data", "data_file.txt")))"];
            name="multi_file2", key="uris-test/folder2", skip_checksum=true)
        @test haskey(db_u2.datasets, "multi_file2")
        @test db_u2.datasets["multi_file2"].uris == ["file://$(abspath(joinpath(@__DIR__, "test-data", "data_file.txt")))"]

        # auto-derived key from common host + path prefix
        db_u_auto = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db_u_auto, ""; name="auto_key",
            uris=["https://example.com/data1/file.nc", "https://example.com/data2/file.nc"],
            skip_checksum=true)
        @test db_u_auto.datasets["auto_key"].key == "example.com"
        register_dataset(db_u_auto, ""; name="auto_key_common",
            uris=["https://example.com/dataset/v1/a.nc", "https://example.com/dataset/v1/b.nc"],
            skip_checksum=true)
        @test db_u_auto.datasets["auto_key_common"].key == "example.com/dataset/v1"

        # TOML round-trip: uris field survives write/read
        uris_toml = joinpath(datasets_dir, "uris_test.toml")
        write(db_u, uris_toml)
        db_u_rt = read_dataset(uris_toml, datasets_dir; persist=false)
        @test db_u_rt.datasets["multi_file"].uris == db_u.datasets["multi_file"].uris

        # TOML syntax: uris as a list in TOML
        toml_str = joinpath(datasets_dir, "uris_toml_syntax.toml")
        write(toml_str, """
        [multi_from_toml]
        key = "uris-toml-test/folder"
        uris = ["file://$(abspath(joinpath(@__DIR__, "test-data", "data_file.txt")))"]
        skip_checksum = true
        """)
        db_toml = read_dataset(toml_str, datasets_dir; persist=false)
        @test haskey(db_toml.datasets, "multi_from_toml")
        @test length(db_toml.datasets["multi_from_toml"].uris) == 1

        # TOML syntax: uri as a list (alias for uris)
        toml_uri_list = joinpath(datasets_dir, "uri_list_syntax.toml")
        write(toml_uri_list, """
        [multi_from_uri_list]
        key = "uris-uri-list-test/folder"
        uri = ["file://$(abspath(joinpath(@__DIR__, "test-data", "data_file.txt")))"]
        skip_checksum = true
        """)
        db_uri_list = read_dataset(toml_uri_list, datasets_dir; persist=false)
        @test haskey(db_uri_list.datasets, "multi_from_uri_list")
        @test length(db_uri_list.datasets["multi_from_uri_list"].uris) == 1
    end


    @testset "storage_path (override the cache location)" begin
        test_file_abs = abspath(joinpath(@__DIR__, "test-data", "data_file.txt"))

        # An exact (user-managed) storage_path with no $key is returned as-is,
        # bypassing datasets_folder/key.
        db_abs = Database(datasets_folder=datasets_dir; persist=false)
        register_dataset(db_abs, ""; name="abs_local",
            uri="https://protected.example.com/data.txt",
            storage_path=test_file_abs, skip_checksum=true)
        @test get_dataset_path(db_abs, "abs_local") == test_file_abs
        # File already exists at storage_path → cache hit, no download attempted.
        @test download_dataset(db_abs, "abs_local") == test_file_abs

        # _remove_dataset_from_disk does not touch a user-managed storage_path file.
        @test isfile(test_file_abs)
        DataManifest.Databases._remove_dataset_from_disk(db_abs, db_abs.datasets["abs_local"])
        @test isfile(test_file_abs)

        # A relative exact storage_path resolves against the Datasets.toml directory.
        lp_dir = mktempdir(prefix="DataManifest_lp_"; cleanup=true)
        toml_path = joinpath(lp_dir, "Datasets.toml")
        mkpath(joinpath(lp_dir, "data"))
        rel_file = joinpath(lp_dir, "data", "in_repo.txt")
        write(rel_file, "hello local")
        write(toml_path, """
        [in_repo]
        uri = "https://protected.example.com/in_repo.txt"
        storage_path = "data/in_repo.txt"
        skip_checksum = true
        """)
        db_rel = read_dataset(toml_path, datasets_dir; persist=true)
        @test get_dataset_path(db_rel, "in_repo") == rel_file
        @test download_dataset(db_rel, "in_repo") == rel_file

        # Cache miss + downloadable URI: download lands at storage_path
        # (storage_path is purely a location override; download mechanism unchanged).
        # NOTE: filename matches the source because the file:// scheme uses rsync,
        # which preserves the source basename.
        fetch_dir = mktempdir(prefix="DataManifest_lp_fetch_"; cleanup=true)
        fetch_toml = joinpath(fetch_dir, "Datasets.toml")
        write(fetch_toml, """
        [fetch_local]
        uri = "file://$test_file_abs"
        storage_path = "fetched/data_file.txt"
        skip_checksum = true
        """)
        db_fetch = read_dataset(fetch_toml, datasets_dir; persist=true)
        fetched_path = joinpath(fetch_dir, "fetched", "data_file.txt")
        @test !isfile(fetched_path)
        @test download_dataset(db_fetch, "fetch_local") == fetched_path
        @test isfile(fetched_path)

        # Missing file with skip_download=true: generic missing-file error citing URI.
        write(toml_path, """
        [missing_skip]
        uri = "https://protected.example.com/missing.txt"
        storage_path = "data/missing.txt"
        skip_download = true
        """)
        db_missing = read_dataset(toml_path, datasets_dir; persist=true)
        err = try
            download_dataset(db_missing, "missing_skip")
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("data/missing.txt", err.msg)
        @test occursin("https://protected.example.com/missing.txt", err.msg)

        # Checksum still applies on cache hit.
        bad_checksum_toml = joinpath(lp_dir, "BadChecksum.toml")
        write(bad_checksum_toml, """
        [bad_sum]
        uri = "https://protected.example.com/in_repo.txt"
        storage_path = "data/in_repo.txt"
        sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        """)
        db_bad = read_dataset(bad_checksum_toml, datasets_dir; persist=true)
        @test_throws ErrorException download_dataset(db_bad, "bad_sum")

        # TOML round-trip: storage_path field survives write/read.
        rt_toml = joinpath(lp_dir, "RoundTrip.toml")
        write(db_rel, rt_toml)
        db_rt = read_dataset(rt_toml, datasets_dir; persist=false)
        @test db_rt.datasets["in_repo"].storage_path == "data/in_repo.txt"
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

    @testset "Cache (@cached produce-or-load)" begin
        C = DataManifest.Cache

        # Normative parameter hash: canonical JSON (JCS) → SHA-256 reference vector.
        kt = Dict("grid" => "5x5", "skip_models" => ["CESM.*", "FGOALS.*"])
        @test C.canonical_json(kt) == "{\"grid\":\"5x5\",\"skip_models\":[\"CESM.*\",\"FGOALS.*\"]}"
        @test param_hash(kt) == "83425a30d111562d46c1fce9de7618ea7f1f54e1be72e086cba0ac63c6f2ce9b"
        # NamedTuple + Symbol coercion + `_`-key exclusion give the same hash.
        @test param_hash((; grid="5x5", skip_models=["CESM.*", "FGOALS.*"])) == param_hash(kt)
        @test param_hash((; grid="5x5", skip_models=["CESM.*", "FGOALS.*"], _parallel=true)) == param_hash(kt)

        # spec-v3.1: finite floats are valid hash inputs, serialized via the normative
        # Python `json.dumps` form. Cross-tool reference vectors (from the Python tool):
        @test C._python_float_repr(1.0) == "1.0"
        @test C._python_float_repr(0.5) == "0.5"
        @test C._python_float_repr(0.15) == "0.15"
        @test C._python_float_repr(1e20) == "1e+20"
        @test C._python_float_repr(1e-5) == "1e-05"
        @test C._python_float_repr(1e16) == "1e+16"
        @test C._python_float_repr(1e15) == "1000000000000000.0"
        @test C._python_float_repr(100.0) == "100.0"
        @test C._python_float_repr(-3.25) == "-3.25"
        @test C._python_float_repr(6.022e23) == "6.022e+23"
        @test C.canonical_json(Dict("x" => 0.15)) == "{\"x\":0.15}"
        @test param_hash(Dict("x" => 0.15)) ==
              "f894f9f6b958c1f5ca3b592741e0e8eda12c480b412b4c4dc810290e1f828cdb"
        @test param_hash(Dict("a" => 1.0, "b" => [2.5, 1e20])) ==
              "6eee4cb6553cb6fd00a62fadbe82bfcc65c23e59564e99cb456ad4f62818ac90"
        # A float and the equal integer render differently → distinct keys.
        @test param_hash(Dict("x" => 1.0)) != param_hash(Dict("x" => 1))
        @test param_hash((; sigma=0.5)) == param_hash(Dict("sigma" => 0.5))  # NamedTuple parity
        # Non-finite floats and nulls remain a hard error, anywhere in the structure.
        @test_throws ErrorException param_hash(Dict("x" => NaN))
        @test_throws ErrorException param_hash(Dict("x" => Inf))
        @test_throws ErrorException param_hash(Dict("x" => -Inf))
        @test_throws ErrorException param_hash(Dict("nested" => [1, Inf]))
        @test_throws ErrorException param_hash(Dict("x" => nothing))

        # @cached round-trip with an explicit cache_dir (jls), + the on-disk layout.
        # `cached_toml` / DATAMANIFEST_USAGE_LOG are pinned to a tempdir so register-on-
        # produce (Phase 2) never touches the repo or the real depot usage log.
        dir = mktempdir()
        idx_path = joinpath(dir, ".datamanifest", "state.toml")
        usage_path = joinpath(dir, "usage.toml")
        calls = Ref(0)
        @cached cachetype="demo" key=(a -> (; a.grid, a.n)) function demo(;
                grid::String="5x5", n::Int=3, _verbose::Bool=false,
                cache_dir=nothing, cached_toml=nothing)
            calls[] += 1
            return Dict("grid" => grid, "n" => n, "sum" => n * 2)
        end
        withenv("DATAMANIFEST_USAGE_LOG" => usage_path) do
            r1 = demo(; grid="5x5", n=3, cache_dir=dir, cached_toml=idx_path)
            r2 = demo(; grid="5x5", n=3, cache_dir=dir, cached_toml=idx_path, _verbose=true)  # hit
            @test calls[] == 1
            @test r1 == r2
            hh = param_hash((; grid="5x5", n=3))
            d = joinpath(dir, "demo", hh)
            for f in ("data.jls", "config.toml", "metadata.toml", ".complete")
                @test isfile(joinpath(d, f))
            end
            @test C.config_is_valid(d)
            @test C.read_config(d).cachetype == "demo"
            @test C.cache_key("demo", hh) == "demo/$hh"

            # Phase 2: register-on-produce wrote the state-file recipe (schema 5: datacache
            # keyed by (cachetype, version), each instance hash -> its artifact dir), and
            # stamped the depot usage log.
            @test isfile(idx_path)
            idx = read_index(idx_path)
            recs = filter(r -> r["cachetype"] == "demo", recipe_records(idx))
            @test length(recs) == 1
            rec = recs[1]
            @test rec["format"] == "jls"
            @test endswith(rec["ref"], ":demo")
            @test haskey(rec["instances"], hh)
            @test rec["instances"][hh] == d   # the per-instance storage_path is the artifact dir
            @test index_keys(idx) == Set(["demo/$hh"])
            @test abspath(idx_path) in C.known_paths(ENV)
            # metadata.toml [origin].state_file back-pointer names the state file.
            md = TOML.parsefile(joinpath(d, "metadata.toml"))
            @test get(get(md, "origin", Dict()), "state_file", "") == abspath(idx_path)

            # cached=false bypasses disk entirely (no recompute-skip, no registration).
            demo(; grid="z", n=9, cache_dir=dir, cached_toml=idx_path, cached=false)
            @test calls[] == 2
        end

        # Produced datasets are keyword-only: a positional arg is rejected at macro time.
        kwonly_err = try
            @eval @cached cachetype="bad" key=(a -> (; a.x)) function _bad_pos(y; x=1)
                y
            end
            ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("keyword-only", kwonly_err)
    end

    @testset "materialize lock semantics (spec-v5.2)" begin
        M = DataManifest.PipeLines
        S = DataManifest.Storage

        # spec-v5.3: the staleness age is the config field `lock_stale_age`, resolved on
        # the ordinary ladder (env → config layers, `_HOST`-composable); TOML number or
        # numeric string; unparsable / non-positive falls back to the default.
        @test S.lock_stale_age(storage_config=Dict{String,Any}()) == 30.0
        @test S.lock_stale_age(storage_config=Dict{String,Any}("lock_stale_age" => 7)) == 7.0
        @test S.lock_stale_age(storage_config=Dict{String,Any}("lock_stale_age" => "8.5")) == 8.5
        @test S.lock_stale_age(storage_config=Dict{String,Any}("lock_stale_age" => -5)) == 30.0
        @test S.lock_stale_age(storage_config=Dict{String,Any}("lock_stale_age" => "junk")) == 30.0
        @test S.lock_stale_age(storage_config=Dict{String,Any}(
            "_HOST" => Dict{String,Any}(gethostname() => Dict{String,Any}("lock_stale_age" => 9)),
            "lock_stale_age" => 7)) == 9.0   # _HOST glob beats the layer base
        withenv("DATAMANIFEST_LOCK_STALE_AGE" => "3") do
            @test S.lock_stale_age(storage_config=Dict{String,Any}("lock_stale_age" => 7)) == 3.0
        end

        d = mktempdir()

        # Baseline publish + skip_if: the recheck under the lock skips the write entirely.
        t = joinpath(d, "obj.bin")
        M.materialize(tmp -> write(tmp, "payload"), t)
        @test read(t, String) == "payload"
        @test S.is_complete(t)
        @test !isfile(S.lock_path(t))
        called = Ref(false)
        M.materialize(t; skip_if=S.is_complete) do tmp
            called[] = true
            write(tmp, "clobber")
        end
        @test !called[]
        @test read(t, String) == "payload"

        # on_locked=:fail raises on a fresh lock held by a live foreign process (pid 1).
        t2 = joinpath(d, "obj2.bin")
        write(S.lock_path(t2), "1 $(gethostname())")
        err = try
            M.materialize(tmp -> write(tmp, "x"), t2; on_locked=:fail)
            ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("locked by another process", err)
        rm(S.lock_path(t2))

        # A stale lock (age > stale_age, dead PID) is reclaimed.
        t3 = joinpath(d, "obj3.bin")
        write(S.lock_path(t3), "999999999 $(gethostname())")
        sleep(0.8)
        M.materialize(tmp -> write(tmp, "y"), t3; on_locked=:fail, stale_age=0.5)
        @test read(t3, String) == "y"

        # Under the default :wait, an ALREADY-stale lock is reclaimed immediately —
        # a contender arriving long after a crash must not wait another stale_age
        # (the stdlib's blocking path alone would; the upfront non-blocking attempt
        # short-circuits it).
        t3b = joinpath(d, "obj3b.bin")
        write(S.lock_path(t3b), "999999999 $(gethostname())")
        sleep(1.2)                     # lock age is now well past stale_age=1.0
        reclaim = @elapsed M.materialize(tmp -> write(tmp, "y2"), t3b; stale_age=1.0)
        @test read(t3b, String) == "y2"
        @test reclaim < 0.9            # reclaimed up front, not after a stale_age wait

        # on_locked=:proceed publishes via process-private staging under a live holder.
        t4 = joinpath(d, "obj4.bin")
        write(S.lock_path(t4), "1 $(gethostname())")
        M.materialize(tmp -> write(tmp, "z"), t4; on_locked=:proceed)
        @test read(t4, String) == "z"
        @test S.is_complete(t4)
        @test isfile(S.lock_path(t4))   # the foreign holder's lock was left untouched
        rm(S.lock_path(t4))

        # Default :wait + skip_if recheck — a contender blocks on the holder's lock, then
        # adopts what the holder published instead of rewriting it.
        t5 = joinpath(d, "obj5.bin")
        ran = String[]
        holder = @async M.materialize(t5) do tmp
            push!(ran, "holder")
            sleep(1.0)
            write(tmp, "holder")
        end
        sleep(0.3)   # let the holder take the lock
        waited = @elapsed M.materialize(t5; skip_if=S.is_complete) do tmp
            push!(ran, "contender")
            write(tmp, "contender")
        end
        wait(holder)
        @test waited > 0.5            # actually blocked until the holder released
        @test ran == ["holder"]       # the contender skipped after the recheck
        @test read(t5, String) == "holder"

        # @cached compute-once under contention: concurrent callers of the same variation
        # wait on the producer, then load its artifact — the body runs exactly once.
        cdir = mktempdir()
        cidx = joinpath(cdir, ".datamanifest", "state.toml")
        cusage = joinpath(cdir, "usage.toml")
        ncalls = Ref(0)
        @cached cachetype="concurrent_demo" key=(a -> (; a.n)) function concurrent_demo(;
                n::Int=0, cache_dir=nothing, cached_toml=nothing)
            ncalls[] += 1
            sleep(0.8)
            return n * 2
        end
        withenv("DATAMANIFEST_USAGE_LOG" => cusage) do
            tasks = [@async concurrent_demo(; n=21, cache_dir=cdir, cached_toml=cidx)
                     for _ in 1:3]
            @test all(==(42), fetch.(tasks))
            @test ncalls[] == 1
        end
    end

    @testset "Cache index + usage + inspect (state file)" begin
        C = DataManifest.Cache

        # --- state-file round-trip (schema 5: datacache + datasets namespaces) ----
        dir = mktempdir()
        idx_path = joinpath(dir, C.STATE_FILE_NAME)
        idx = read_index_or_empty(idx_path)
        @test isempty(idx.recipes) && isempty(idx.datasets)
        register!(idx; cachetype="esm_20c", hash="a"^64,
                  storage_path="cached/esm_20c/v3/$("a"^64)",
                  ref="P:load_20c", format="nc", version="v3")
        register!(idx; cachetype="esm_lgm", hash="b"^64, storage_path="cached/esm_lgm/$("b"^64)",
                  ref="P:load_lgm")
        register_dataset!(idx; key="ex.com/foo.nc", storage_path="datasets/ex.com/foo.nc",
                          sha256="abc123")
        write_index(idx)
        @test isfile(idx_path)
        back = read_index(idx_path)
        @test Set(keys(back.recipes)) == Set([("esm_20c", "v3"), ("esm_lgm", "")])
        # instances map hash -> the artifact dir (storage_path), NOT params (params live in config.toml).
        @test back.recipes[("esm_20c", "v3")]["instances"]["a"^64] == "cached/esm_20c/v3/$("a"^64)"
        @test index_keys(back) == Set(["esm_20c/$("a"^64)", "esm_lgm/$("b"^64)"])
        @test reachable_keys(back) ==
              Set([("esm_20c", "v3", "a"^64), ("esm_lgm", "", "b"^64)])
        @test ref_of(back; cachetype="esm_20c", version="v3") == "P:load_20c"
        @test has_instance(back; cachetype="esm_20c", version="v3", hash="a"^64)
        @test instance_path_of(back; cachetype="esm_20c", version="v3", hash="a"^64) ==
              "cached/esm_20c/v3/$("a"^64)"
        # datasets namespace round-trips location + actual sha256.
        @test dataset_path_of(back, "ex.com/foo.nc") == "datasets/ex.com/foo.nc"
        @test dataset_sha256_of(back, "ex.com/foo.nc") == "abc123"
        # _META schema 5 is written.
        @test TOML.parsefile(idx_path)["_META"]["schema"] == 5
        # Registering a new hash ACCUMULATES under the recipe (does not overwrite it).
        register!(back; cachetype="esm_20c", hash="c"^64, version="v3")
        @test Set(keys(back.recipes[("esm_20c", "v3")]["instances"])) == Set(["a"^64, "c"^64])
        @test haskey(back.recipes, ("esm_lgm", ""))

        # A legacy `cached.toml` (schema 2, nested, params-in-body) is read & migrated forward.
        legdir = mktempdir()
        write(joinpath(legdir, "cached.toml"), """
        [_META]
        schema = 2
        [[produced]]
        cachetype = "esm"
        ref = "m:f"
        format = "nc"
          [[produced.instances]]
          hash = "$("d"^64)"
          [produced.instances.params]
          grid = "5x5"
        """)
        @test endswith(C.locate_state(legdir), "cached.toml")   # legacy name found
        lg = read_index(legdir)
        @test reachable_keys(lg) == Set([("esm", "", "d"^64)])
        @test endswith(write_index(lg, legdir), C.STATE_FILE_NAME)  # migrated on write
        @test isfile(joinpath(legdir, C.STATE_FILE_NAME))
        @test !isfile(joinpath(legdir, "cached.toml"))   # legacy file relocated (removed)

        # --- usage log + last-access ----------------------------------------------
        usage_path = joinpath(dir, "usage.toml")
        env = Dict("DATAMANIFEST_USAGE_LOG" => usage_path)
        @test C.usage_log_path(env) == usage_path
        C.record_path!(idx_path; env=env)
        C.record_path!("/tmp/other/datasets.toml"; env=env)
        @test Set(C.known_paths(env)) == Set([abspath(idx_path), "/tmp/other/datasets.toml"])

        # last-access (spec-v3.2): purely filesystem-derived, never written on read.
        # Empty for a missing path; a non-empty stamp for an existing one (atime, or the
        # mtime fallback when atime is unreadable). No reader-side write API exists.
        @test last_access(joinpath(dir, "nope")) == ""
        f = joinpath(dir, "stamp.txt"); write(f, "x")
        @test !isempty(last_access(f))
        @test !isdefined(C, :touch_last_access!)   # no touch-on-read mechanism

        # --- enumerate / delete / move via a real produce -------------------------
        cache_dir = joinpath(dir, "store")
        usage2 = joinpath(dir, "usage2.toml")
        @cached cachetype="thing" key=(a -> (; a.k)) function _thing(;
                k::String="x", cache_dir=nothing, cached_toml=nothing)
            return "value-$k"
        end
        withenv("DATAMANIFEST_USAGE_LOG" => usage2) do
            _thing(; k="one", cache_dir=cache_dir, cached_toml=joinpath(dir, "c2.toml"))
            _thing(; k="two", cache_dir=cache_dir, cached_toml=joinpath(dir, "c2.toml"))
        end
        # enumerate the produced artifacts directly under cache_dir.
        objs = enumerate_artifacts(cache_dir)
        @test length(objs) == 2
        @test all(o -> o.kind == "cached", objs)
        @test all(o -> startswith(o.key, "thing/"), objs)
        @test all(o -> o.format == "jls", objs)
        @test all(o -> o.size > 0, objs)
        @test all(o -> o.referenced === nothing, objs)   # composition root sets this

        # delete refuses non-cached objects; deletes a cached one + its markers.
        fetched = CacheObject(kind="datasets", location=cache_dir)
        @test_throws ErrorException delete_object(fetched)
        @test_throws ErrorException move_object(fetched, dir)
        victim = objs[1]
        delete_object(victim)
        @test !isdir(victim.location)
        @test !isfile(victim.location * ".complete")
        @test length(enumerate_artifacts(cache_dir)) == 1

        # move preserves the <cachetype>/<hash> key path under the destination root.
        survivor = enumerate_artifacts(cache_dir)[1]
        dest = joinpath(dir, "archive")
        newloc = move_object(survivor, dest)
        @test isdir(newloc)
        @test !isdir(survivor.location)
        @test newloc == joinpath(dest, survivor.cachetype, survivor.hash)
    end

    @testset "spec-v3.3 bindings + delegation (rung 3)" begin
        DB = DataManifest.Databases
        P  = DataManifest.PipeLines

        # --- Project-wide loaders accept string|table; ref-only writes as a string ---
        mktempdir() do d
            toml = joinpath(d, "datasets.toml")
            write(toml, """
            [_META]
            schema = 1

            [_LANG.julia.loaders]
            nc  = "NCDatasets:Dataset"
            csv = { ref = "CSV:read" }
            grid = { ref = "MyPkg:load", kwargs = { res = "5x5" } }

            [ds]
            uri = "https://example.com/x.nc"
            format = "nc"
            """)
            db = read_dataset(toml, d; persist=false)
            @test db.lang_julia_loaders["nc"] == "NCDatasets:Dataset"
            @test db.lang_julia_loaders["csv"] isa AbstractDict     # raw binding kept
            @test db.lang_julia_loaders["grid"]["kwargs"]["res"] == "5x5"

            out = joinpath(d, "out.toml")
            write(db, out)
            txt = read(out, String)
            @test occursin("nc = \"NCDatasets:Dataset\"", txt)
            @test occursin("csv = \"CSV:read\"", txt)         # ref-only → bare string
            @test occursin("ref = \"MyPkg:load\"", txt)       # parameterized → table
            # Round-trips back identically.
            db2 = read_dataset(out, d; persist=false)
            @test db2.lang_julia_loaders["csv"] == "CSV:read"  # normalized on write
            @test db2.lang_julia_loaders["grid"]["kwargs"]["res"] == "5x5"
        end

        # --- Delegation (rung 3) gating helpers ---
        # A foreign (python) fetcher with no julia/shell fetcher and no uri is delegated.
        e = DB.DatasetEntry(; extra=Dict{String,Any}(
            "_LANG" => Dict{String,Any}("python" => Dict{String,Any}("fetcher" => "m:f"))))
        @test P._foreign_fetcher_langs(e) == ["python"]
        @test P._should_delegate(e) == true
        # `delegate = false` disables it.
        e_off = DB.DatasetEntry(; extra=Dict{String,Any}(
            "delegate" => false,
            "_LANG" => Dict{String,Any}("python" => Dict{String,Any}("fetcher" => "m:f"))))
        @test P._should_delegate(e_off) == false
        # julia/shell fetchers are not "foreign"; a uri-only dataset has none.
        e_shell = DB.DatasetEntry(; extra=Dict{String,Any}(
            "_LANG" => Dict{String,Any}("shell" => Dict{String,Any}("fetcher" => "make x"))))
        @test isempty(P._foreign_fetcher_langs(e_shell))
        @test isempty(P._foreign_fetcher_langs(DB.DatasetEntry(; uri="https://x/y.nc")))
        # _delegate_fetch is a no-op (false) when there is no manifest on disk.
        db_mem = DB.Database(persist=false)
        @test P._delegate_fetch(db_mem, "ds") == false

        # spec-v3.5: the dataset's shell command is the bare `shell` field (preferred over
        # the legacy [_LANG.shell].fetcher).
        e_bare = DB.DatasetEntry(; shell="make x")
        @test P._shell_command(e_bare) == "make x"
        e_legacy = DB.DatasetEntry(; extra=Dict{String,Any}(
            "_LANG" => Dict{String,Any}("shell" => Dict{String,Any}("fetcher" => "old"))))
        @test P._shell_command(e_legacy) == "old"
        # spec-v3.4: bare fetcher ref (string + table form).
        @test P._bare_fetcher_ref(DB.DatasetEntry(; extra=Dict{String,Any}("fetcher" => "M:f"))) == "M:f"
        @test P._bare_fetcher_ref(DB.DatasetEntry(; extra=Dict{String,Any}(
            "fetcher" => Dict{String,Any}("ref" => "M:f")))) == "M:f"

        # spec-v3.6: a present bare loader that does not resolve is an ERROR — it MUST NOT
        # fall through to the built-in csv loader (which would otherwise succeed here).
        e_bad = DB.DatasetEntry(; format="csv", loader="NoSuchModule12345abc:nope")
        @test_throws Exception P._resolve_loader_v1(DB.Database(persist=false), e_bad)
    end

    @testset "spec-v3.5 bare shell fetch (end-to-end)" begin
        # A v1 dataset with a bare `shell` command and no uri is produced via fetch ladder
        # rung 2 (bare shell), then resolves on disk — no _LANG.shell wrapper needed.
        mktempdir() do d
            src = joinpath(d, "src.txt"); write(src, "from-bare-shell")
            toml = joinpath(d, "datasets.toml")
            write(toml, """
            [_META]
            schema = 1

            [made]
            format = "txt"
            key    = "made"
            shell  = "cp $src \$download_path"
            """)
            db = read_dataset(toml, joinpath(d, "store"); persist=false)
            path = download_dataset(db, "made")
            @test isfile(path)
            @test strip(read(path, String)) == "from-bare-shell"
        end
    end
end

@testset "Conformance suite (pinned spec tag)" begin
    # Source of truth: github.com/perrette/datamanifest.toml (tag pinned below).
    # The pin file records the spec tag + per-file sha256 of each fixture; hashes
    # are over file contents (not the tarball), keeping the pin robust to GitHub
    # re-generating the auto-archive. The tag + content pin is this tool's
    # machine-checkable conformance claim. Unsupported-capability fixtures are
    # skipped with a logged reason — divergent pace is a capability subset, not a
    # spec fork.
    using Downloads, SHA, Tar, CodecZlib, JSON

    pin = TOML.parsefile(joinpath(@__DIR__, "conformance_pin.toml"))
    spec_tag = pin["spec_tag"]
    file_pins = pin["files"]  # relpath -> sha256

    tarball_url = "https://github.com/perrette/datamanifest.toml/archive/refs/tags/$(spec_tag).tar.gz"

    tarball_path = try
        Downloads.download(tarball_url)
    catch e
        @info "Conformance suite skipped: spec tarball unreachable" exception=e
        nothing
    end

    if tarball_path !== nothing
        extracted_dir = mktempdir()
        try
            open(tarball_path) do io
                stream = CodecZlib.GzipDecompressorStream(io)
                try
                    Tar.extract(stream, extracted_dir)
                finally
                    close(stream)
                end
            end
            rm(tarball_path; force=true)

            top_dirs = filter(isdir, readdir(extracted_dir; join=true))
            @test length(top_dirs) == 1
            extracted_root = top_dirs[1]
            fixtures_top = joinpath(extracted_root, "tests", "fixtures")

            # Verify every pinned file against its recorded sha256 (no missing, no extra)
            for (pinned_rel, expected_sha) in file_pins
                fpath = joinpath(extracted_root, pinned_rel)
                @test isfile(fpath)
                actual_sha = bytes2hex(SHA.sha256(read(fpath)))
                @test actual_sha == expected_sha
            end
            for (root, _, files) in walkdir(fixtures_top)
                for fname in files
                    rel_key = replace(relpath(joinpath(root, fname), extracted_root), '\\' => '/')
                    @test haskey(file_pins, rel_key)
                end
            end

            # Capabilities this tool implements; drives which fixtures are run.
            # `cache-produce` = the @cached produce-or-load layer (DataManifest.Cache).
            # `inspect` = the cached.toml index + store-maintenance surface (Phase 2).
            # `delegation` = cross-language fetch rung 3 via the peer `datamanifest` CLI.
            # `sync` (cross-machine push/pull) is not yet implemented.
            SUPPORTED_CAPABILITIES = Set(["lang-read", "lang-write", "shell-fetch",
                                          "storage", "binding-args", "byte-identity",
                                          "cache-produce", "inspect", "delegation"])

            toml_fnames = sort(filter(f -> endswith(f, ".toml"), readdir(fixtures_top)))
            for toml_fname in toml_fnames
                base = toml_fname[1:end-5]
                expected_path = joinpath(fixtures_top, base * ".expected.json")
                isfile(expected_path) || continue
                toml_path = joinpath(fixtures_top, toml_fname)

                expected = JSON.parsefile(expected_path)
                caps = Set(String.(get(expected, "capabilities", String[])))

                if !issubset(caps, SUPPORTED_CAPABILITIES)
                    @info "Skipping fixture $base: requires unsupported capabilities $(setdiff(caps, SUPPORTED_CAPABILITIES))"
                    continue
                end

                @testset "Fixture: $base" begin
                    tmp_dir = mktempdir()
                    try
                        if haskey(expected, "config_sidecar")
                            # cache-produce: a config.toml sidecar (NOT a datasets.toml).
                            # Recompute the param hash from the key table (every root key
                            # except [_META]) and check it equals both the recorded
                            # _META.hash and the fixture's expected hash + key.
                            cs = expected["config_sidecar"]
                            cfg = TOML.parsefile(toml_path)
                            meta = cfg["_META"]
                            key_table = Dict{String,Any}(k => v for (k, v) in cfg if k != "_META")
                            ph = DataManifest.Cache.param_hash(key_table)
                            @test ph == cs["param_hash"]
                            @test ph == meta["hash"]
                            @test String(meta["cachetype"]) == cs["cachetype"]
                            @test DataManifest.Cache.cache_key(String(meta["cachetype"]), ph) == cs["key"]
                            @test key_table == Dict{String,Any}(String(k) => v for (k, v) in cs["key_table"])
                        elseif haskey(expected, "cached_index")
                            # inspect: a cached.toml produced-dataset index (schema 2 nested).
                            # Read it and check each recipe's identity + fields + per-variation
                            # instances match the fixture (it is NOT a datasets.toml). The index
                            # is self-verifying: each instance hash == the param-hash of its params.
                            ci = expected["cached_index"]
                            raw = TOML.parsefile(toml_path)
                            @test raw["_META"]["schema"] == get(ci, "schema", 2)
                            idx = DataManifest.Cache.read_index(toml_path)
                            # forbidden_keys: a negative assertion against _META and every recipe.
                            forbidden = Set(String.(get(ci, "forbidden_keys", String[])))
                            if !isempty(forbidden)
                                @test isempty(intersect(forbidden, Set(string.(keys(raw["_META"])))))
                                for rrec in get(raw, "produced", Any[])
                                    @test isempty(intersect(forbidden, Set(string.(keys(rrec)))))
                                end
                            end
                            exp_keys = Set{String}()
                            exp_reachable = Set{NTuple{3,String}}()
                            for er in ci["recipes"]
                                ct = String(er["cachetype"])
                                ver = String(get(er, "version", ""))
                                key = (ct, ver)
                                @test haskey(idx.recipes, key)
                                rec = idx.recipes[key]
                                @test rec["ref"] == get(er, "ref", "")
                                @test rec["format"] == get(er, "format", "")
                                for inst in er["instances"]
                                    h = String(inst["hash"])
                                    @test haskey(rec["instances"], h)
                                    params = get(inst, "params", Dict{String,Any}())
                                    @test DataManifest.Cache.param_hash(params) == h
                                    push!(exp_keys, "$(ct)/$(h)")
                                    push!(exp_reachable, (ct, ver, h))
                                end
                            end
                            @test DataManifest.Cache.index_keys(idx) == exp_keys
                            @test DataManifest.Cache.reachable_keys(idx) == exp_reachable
                        else
                        db = read_dataset(toml_path, tmp_dir; persist=false)

                        # Resolution check: compare model against expected Julia rows
                        julia_res = get(get(expected, "resolution", Dict()), "julia", nothing)
                        if julia_res !== nothing
                            for (ds_name, ds_exp) in julia_res
                                @test haskey(db.datasets, ds_name)
                                if haskey(db.datasets, ds_name)
                                    entry = db.datasets[ds_name]

                                    fetch_exp = ds_exp["fetcher"]
                                    actual_fetch = _conf_infer_fetcher(db, entry)
                                    @test actual_fetch !== nothing
                                    if actual_fetch !== nothing
                                        @test actual_fetch[1] == fetch_exp["rung"]
                                        @test actual_fetch[2] == fetch_exp["ref"]
                                    end

                                    load_exp = ds_exp["loader"]
                                    actual_load = _conf_infer_loader(db, entry)
                                    @test actual_load !== nothing
                                    if actual_load !== nothing
                                        @test actual_load[1] == load_exp["rung"]
                                        @test actual_load[2] == load_exp["ref"]
                                    end
                                end
                            end
                        end

                        # Verbatim round-trip: foreign _LANG.* and unknown _* survive write→read
                        orig_dict = TOML.parsefile(toml_path)
                        tmp_toml = joinpath(tmp_dir, "round_trip.toml")
                        write(db, tmp_toml)
                        written_dict = TOML.parsefile(tmp_toml)

                        pv = expected["preserve_verbatim"]

                        for key in get(pv, "unknown_structural", String[])
                            @test haskey(written_dict, key)
                            @test get(written_dict, key, nothing) == get(orig_dict, key, nothing)
                        end

                        for ns in get(get(pv, "lang_namespaces", Dict()), "top_level", String[])
                            parts = split(ns, "."; limit=2)
                            top_key, sub_key = String(parts[1]), String(parts[2])
                            @test haskey(get(written_dict, top_key, Dict()), sub_key)
                            @test get(get(written_dict, top_key, Dict()), sub_key, nothing) ==
                                  get(get(orig_dict, top_key, Dict()), sub_key, nothing)
                        end

                        per_ds = get(get(pv, "lang_namespaces", Dict()), "per_dataset", Dict())
                        for (ds_name, namespaces) in per_ds
                            for ns in namespaces
                                parts = split(ns, "."; limit=2)
                                top_key, sub_key = String(parts[1]), String(parts[2])
                                ds_written = get(written_dict, ds_name, Dict())
                                ds_orig = get(orig_dict, ds_name, Dict())
                                @test haskey(get(ds_written, top_key, Dict()), sub_key)
                                @test get(get(ds_written, top_key, Dict()), sub_key, nothing) ==
                                      get(get(ds_orig, top_key, Dict()), sub_key, nothing)
                            end
                        end

                        # binding-args: the resolved Julia binding carries args
                        # (ordered) + kwargs matching the fixture, pre-$var.
                        binding_args = get(expected, "binding_args", nothing)
                        if binding_args !== nothing
                            jul = get(binding_args, "julia", Dict())
                            for (ds_name, rungs) in jul
                                @test haskey(db.datasets, ds_name)
                                if haskey(db.datasets, ds_name)
                                    entry = db.datasets[ds_name]
                                    if haskey(rungs, "fetcher")
                                        fe = rungs["fetcher"]
                                        @test entry.lang_julia_fetcher_args ==
                                              get(fe, "args", Any[])
                                        @test entry.lang_julia_fetcher_kwargs ==
                                              get(fe, "kwargs", Dict{String,Any}())
                                    end
                                    if haskey(rungs, "loader")
                                        le = rungs["loader"]
                                        @test entry.lang_julia_loader_args ==
                                              get(le, "args", Any[])
                                        @test entry.lang_julia_loader_kwargs ==
                                              get(le, "kwargs", Dict{String,Any}())
                                    end
                                end
                            end
                        end

                        # storage (spec-v4): the two folder fields, the user-symbol
                        # namespace, the _HOST patterns, and per-dataset storage_path
                        # expressions match the fixture's storage block. Raw [_STORAGE]
                        # values are path expressions; compared verbatim (not resolved).
                        storage_exp = get(expected, "storage", nothing)
                        if storage_exp !== nothing
                            sc = db.storage_config

                            # The two folder fields + the project name: raw [_STORAGE] values.
                            for fieldname in ("datasets_dir", "datacache_dir", "project")
                                if haskey(storage_exp, fieldname)
                                    @test String(get(sc, fieldname, "")) ==
                                          storage_exp[fieldname]
                                end
                            end

                            # User-defined symbols (bare [_STORAGE] keys, reserved excluded).
                            @test DataManifest.Storage.user_symbols(sc) ==
                                  sort(String.(get(storage_exp, "symbols", String[])))

                            # _HOST glob patterns.
                            host = get(sc, "_HOST", Dict())
                            @test sort(collect(keys(host))) ==
                                  sort(String.(get(storage_exp, "host_patterns", String[])))

                            # Per-dataset storage_path expressions (raw, pre-expansion).
                            for (ds_name, sp_exp) in get(storage_exp, "storage_paths", Dict())
                                @test haskey(db.datasets, ds_name)
                                if haskey(db.datasets, ds_name)
                                    @test db.datasets[ds_name].storage_path == sp_exp
                                end
                            end
                        end

                        # byte-identity (self-consistent): serialize → parse →
                        # serialize is byte-stable and key-sorted at every level.
                        # No cross-tool diff yet — pending the Python tool.
                        s1 = read(tmp_toml, String)
                        db2 = read_dataset(tmp_toml, tmp_dir; persist=false)
                        tmp_toml2 = joinpath(tmp_dir, "round_trip2.toml")
                        write(db2, tmp_toml2)
                        s2 = read(tmp_toml2, String)
                        @test s1 == s2
                        end  # config_sidecar vs datasets.toml branch
                    finally
                        rm(tmp_dir; force=true, recursive=true)
                    end
                end
            end
        finally
            rm(extracted_dir; force=true, recursive=true)
        end
    end
end

finally
    rm(datasets_dir; force=true, recursive=true)
end