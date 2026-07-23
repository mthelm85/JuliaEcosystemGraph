# ── SHACL shapes ──────────────────────────────────────────────────────────────
#
# Structural sanity checks run at assembly time against the union of the
# default graph and the current snapshot graph.

function _property_shape!(g::Graph, shape::IRI, path::IRI;
                          min::Union{Int,Nothing}=nothing,
                          max::Union{Int,Nothing}=nothing,
                          datatype::Union{IRI,Nothing}=nothing,
                          class::Union{IRI,Nothing}=nothing)
    b = blank!(g)
    push!(g, Triple(shape, sh.property, b))
    push!(g, Triple(b, sh.path, path))
    isnothing(min)      || push!(g, Triple(b, sh.minCount, Literal(min)))
    isnothing(max)      || push!(g, Triple(b, sh.maxCount, Literal(max)))
    isnothing(datatype) || push!(g, Triple(b, sh.datatype, datatype))
    isnothing(class)    || push!(g, Triple(b, sh.class, class))
    b
end

function build_shapes()::Graph
    g   = Graph()
    shp = Namespace("https://julia-ecosystem.org/shapes/")

    # Every package has exactly one name and one UUID; dependencies point at
    # packages; version counts are integers.
    push!(g, Triple(shp.PackageShape, rdf.type, sh.NodeShape))
    push!(g, Triple(shp.PackageShape, sh.targetClass, jl.Package))
    _property_shape!(g, shp.PackageShape, rdfs.label;         min=1, max=1, datatype=xsd.string)
    _property_shape!(g, shp.PackageShape, dcterms.identifier; min=1, max=1, datatype=xsd.string)
    _property_shape!(g, shp.PackageShape, jl.dependsOn;       class=jl.Package)
    _property_shape!(g, shp.PackageShape, jl.versionCount;    min=1, max=1, datatype=xsd.integer)

    # Every package snapshot points at exactly one package and carries a date.
    push!(g, Triple(shp.SnapshotShape, rdf.type, sh.NodeShape))
    push!(g, Triple(shp.SnapshotShape, sh.targetClass, jl.PackageSnapshot))
    _property_shape!(g, shp.SnapshotShape, jl.forPackage,      min=1, max=1, class=jl.Package)
    _property_shape!(g, shp.SnapshotShape, jl.observedAt,      min=1, max=1, datatype=xsd.date)
    _property_shape!(g, shp.SnapshotShape, jl.stars,            max=1, datatype=xsd.integer)
    _property_shape!(g, shp.SnapshotShape, jl.monthlyDownloads, max=1, datatype=xsd.integer)
    _property_shape!(g, shp.SnapshotShape, jl.contributorCount, max=1, datatype=xsd.integer)

    # Every contributor node has a login.
    push!(g, Triple(shp.PersonShape, rdf.type, sh.NodeShape))
    push!(g, Triple(shp.PersonShape, sh.targetClass, foaf.Person))
    _property_shape!(g, shp.PersonShape, foaf.nick, min=1, max=1, datatype=xsd.string)

    g
end
