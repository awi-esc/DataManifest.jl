# Helper script for command-based dataset test.
# Usage: julia write_dummy.jl <output_dir> [content]
# Writes <output_dir>/dummy.txt with content (default "dummy").
content = length(ARGS) > 1 ? ARGS[2] : "dummy"
write(joinpath(ARGS[1], "dummy.txt"), content)
