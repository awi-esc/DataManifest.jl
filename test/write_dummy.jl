# Helper script for command-based dataset test.
# Usage: julia write_dummy.jl <output_dir> [content]
# Writes <output_dir>/dummy.txt with content (default "dummy").
# Creates output_dir if needed (matches documented behavior: command creates output dir).
content = length(ARGS) > 1 ? ARGS[2] : "dummy"
output_dir = ARGS[1]
mkpath(output_dir)
write(joinpath(output_dir, "dummy.txt"), content)
