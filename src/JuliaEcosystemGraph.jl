module JuliaEcosystemGraph

using RDF
using Dates
using Printf
using Downloads
import JSON
import Pkg
import Graphs

include("config.jl")
include("state.jl")
include("gh_client.jl")
include("ontology.jl")
include("registry.jl")
include("github_graphql.jl")
include("contributors.jl")
include("users.jl")
include("downloads.jl")
include("derived.jl")
include("shapes.jl")
include("assemble.jl")
include("build.jl")

export build

end # module JuliaEcosystemGraph
