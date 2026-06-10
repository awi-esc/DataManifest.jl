# Config: paths, logging, SHA-256. No dependency on DataBase or PipeLines.
module Config

using Logging
using SHA

# ConsoleLogger API: show_limited/right_justify added in Julia 1.9
function _meta_formatter(level::LogLevel, _module, group, id, file, line)
    _base = ConsoleLogger(Logging.Info; show_limited=true, right_justify=0)
    color, prefix, suffix = _base.meta_formatter(level, _module, group, id, file, line)
    return (color, "DataManifest", suffix)
end
const logger = ConsoleLogger(Logging.Info; show_limited=true, right_justify=0, meta_formatter=_meta_formatter)

function info(msg::String)
    with_logger(logger) do
        @info(msg)
    end
end

function warn(msg::String)
    with_logger(logger) do
        @warn(msg)
    end
end

function sha256_file(file_path)
    open(file_path, "r") do file
        ctx = SHA256_CTX()
        buffer = Vector{UInt8}(undef, 1024)
        while !eof(file)
            bytes_read = readbytes!(file, buffer)
            update!(ctx, buffer[1:bytes_read])
        end
        return bytes2hex(digest!(ctx))
    end
end

function sha256_folder(folder_path)
    ctx = SHA256_CTX()
    for (root, dirs, files) in walkdir(folder_path)
        for file in files
            file_path = joinpath(root, file)
            open(file_path, "r") do f
                while !eof(f)
                    data = read(f, 1024)
                    update!(ctx, data)
                end
            end
        end
    end
    return bytes2hex(digest!(ctx))
end

function sha256_path(path::String)
    if isfile(path)
        return sha256_file(path)
    elseif isdir(path)
        return sha256_folder(path)
    else
        error("Path does not exist: $path")
    end
end

# Generic digest dispatch over the algorithms this implementation can compute.
# `checksum = "<algo>:<hex>"` may name any algorithm both writer and reader
# implement; the SHA stdlib gives us the SHA family but not md5, so an algorithm
# we cannot compute (e.g. md5) raises here and the caller (verify_checksum) warns
# and skips rather than failing or silently rewriting it to sha256.
const _HASH_CTX = Dict{String,DataType}(
    "sha1" => SHA1_CTX, "sha224" => SHA224_CTX, "sha256" => SHA256_CTX,
    "sha384" => SHA384_CTX, "sha512" => SHA512_CTX,
)

hashable_algo(algo::String) = haskey(_HASH_CTX, algo)

function hash_file(file_path, algo::String="sha256")
    ctx_type = get(_HASH_CTX, algo, nothing)
    ctx_type === nothing && error("unsupported hash algorithm: $algo")
    open(file_path, "r") do file
        ctx = ctx_type()
        buffer = Vector{UInt8}(undef, 1024)
        while !eof(file)
            bytes_read = readbytes!(file, buffer)
            update!(ctx, buffer[1:bytes_read])
        end
        return bytes2hex(digest!(ctx))
    end
end

function hash_folder(folder_path, algo::String="sha256")
    ctx_type = get(_HASH_CTX, algo, nothing)
    ctx_type === nothing && error("unsupported hash algorithm: $algo")
    ctx = ctx_type()
    for (root, dirs, files) in walkdir(folder_path)
        for file in files
            open(joinpath(root, file), "r") do f
                while !eof(f)
                    update!(ctx, read(f, 1024))
                end
            end
        end
    end
    return bytes2hex(digest!(ctx))
end

function hash_path(path::String, algo::String="sha256")
    if isfile(path)
        return hash_file(path, algo)
    elseif isdir(path)
        return hash_folder(path, algo)
    else
        error("Path does not exist: $path")
    end
end

# Path constants
const XDG_CACHE_HOME = get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache"))
const DEFAULT_DATASETS_FOLDER_PATH = joinpath(XDG_CACHE_HOME, "Datasets")
const DEFAULT_DATASETS_TOML_PATH = ""
const COMPRESSED_FORMATS = ["zip", "tar.gz", "tar"]
const HIDE_STRUCT_FIELDS = [:host, :path, :scheme]

function get_extract_path(path::String)
    for format in COMPRESSED_FORMATS
        if endswith(path, ".$format")
            return path[1:end-length(format)-1]
        end
        if occursin("?format=$format", path)
            return rstrip(replace(path, "?format=$format", "?"), '?')
        end
    end
    return path * ".d"
end

"""
Project root from datasets_toml path and/or current project path.
Used by Databases.get_project_root(db) so Config stays free of Database.
"""
function project_root_from_paths(datasets_toml_path::String, current_project_path::Union{Nothing,String})
    if datasets_toml_path != ""
        return abspath(dirname(datasets_toml_path))
    end
    if current_project_path !== nothing && current_project_path != ""
        return abspath(dirname(current_project_path))
    end
    return ""
end

function get_default_toml()
    if isfile(DEFAULT_DATASETS_TOML_PATH)
        return DEFAULT_DATASETS_TOML_PATH
    end
    for envvar in ["DATAMANIFEST_TOML", "DATASETS_TOML"]
        if envvar in keys(ENV) && ENV[envvar] != ""
            env_toml = ENV[envvar]
            if !isfile(env_toml)
                warn("Environment variable $envvar points to a non-existing file: $env_toml.")
            end
            return env_toml
        end
    end
    if Base.current_project() !== nothing && Base.current_project() == Base.active_project()
        root = abspath(dirname(Base.current_project()))
        currentdefault = joinpath(root, "Datasets.toml")
        alternatives = [
            joinpath(root, "DataManifest.toml"),
            joinpath(root, "datasets.toml")
        ]
        if !isfile(currentdefault)
            for alt in alternatives
                if isfile(alt)
                    currentdefault = alt
                    return alt
                end
            end
        end
        return currentdefault
    else
        warn("The project is not activated. Cannot infer default datasets_toml path. In-memory database will be used.")
        return ""
    end
end

end # module Config
