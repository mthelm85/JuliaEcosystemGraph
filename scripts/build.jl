# Build the Julia package ecosystem knowledge graph.
#
#   julia --project -t auto scripts/build.jl                 # full pipeline
#   julia --project -t auto scripts/build.jl registry assemble   # specific phases
#
# Requires GITHUB_TOKEN.  Interrupt any time — progress is checkpointed and
# the next run resumes where it left off.  PKG_LIMIT=40 for a quick smoke run.

using JuliaEcosystemGraph

build(phases=Symbol.(ARGS))
