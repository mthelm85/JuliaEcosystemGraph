# ── Ontology ──────────────────────────────────────────────────────────────────
#
# Classes and properties are declared with labels, comments, and domain/range
# so that describe_schema/to_prompt produce a self-explanatory schema and RDFS
# inference has something to work with.  Standard vocabularies are reused
# wherever a term exists (dcterms, foaf, skos, schema.org); jl: terms cover
# what's Julia- or GitHub-specific.

function _declare_class!(g::Graph, cls::IRI, label::String, comment::String)
    push!(g, Triple(cls, rdf.type, rdfs.Class))
    push!(g, Triple(cls, rdfs.label, Literal(label)))
    push!(g, Triple(cls, rdfs.comment, Literal(comment)))
end

function _declare_prop!(g::Graph, prop::IRI, label::String, comment::String;
                        domain::Union{IRI,Nothing}=nothing,
                        range::Union{IRI,Nothing}=nothing)
    push!(g, Triple(prop, rdf.type, rdf.Property))
    push!(g, Triple(prop, rdfs.label, Literal(label)))
    push!(g, Triple(prop, rdfs.comment, Literal(comment)))
    isnothing(domain) || push!(g, Triple(prop, rdfs.domain, domain))
    isnothing(range)  || push!(g, Triple(prop, rdfs.range, range))
end

function build_ontology!(g::Graph)
    # ── Classes ──
    _declare_class!(g, jl.Package, "Julia Package",
        "A package registered in the Julia General registry. IRIs are JuliaHub package pages.")
    push!(g, Triple(jl.Package, rdfs.subClassOf, sdo.SoftwareSourceCode))
    _declare_class!(g, jl.Snapshot, "Ecosystem Snapshot",
        "One dated observation of the whole ecosystem; links to per-package snapshots via jl:hasPackageSnapshot.")
    _declare_class!(g, jl.PackageSnapshot, "Package Snapshot",
        "Time-varying metrics for one package on one date, stored in that date's named graph.")

    # ── Structural package properties (default graph) ──
    _declare_prop!(g, jl.dependsOn, "depends on",
        "Direct dependency of the package's latest registered version.";
        domain=jl.Package, range=jl.Package)
    _declare_prop!(g, jl.owner, "owner",
        "GitHub account (user or organization) that owns the package's repository.";
        domain=jl.Package, range=foaf.Agent)
    _declare_prop!(g, jl.minJuliaVersion, "minimum Julia version",
        "Julia compat lower bound declared by the latest registered version."; domain=jl.Package)
    _declare_prop!(g, jl.versionCount, "version count",
        "Number of versions ever registered in General."; domain=jl.Package)
    _declare_prop!(g, jl.latestVersion, "latest version",
        "Highest version number registered in General."; domain=jl.Package)
    _declare_prop!(g, jl.subdirectory, "subdirectory",
        "Path within the repository for packages that live in a monorepo."; domain=jl.Package)
    _declare_prop!(g, jl.isJLL, "is JLL binary wrapper",
        "True for auto-generated *_jll binary wrapper packages."; domain=jl.Package)
    _declare_prop!(g, jl.isStdlib, "is standard library",
        "True for Julia standard libraries that are also registered in General."; domain=jl.Package)
    _declare_prop!(g, jl.isFork, "is fork",
        "True when the repository is a GitHub fork."; domain=jl.Package)
    _declare_prop!(g, jl.forkParent, "fork parent",
        "Repository this repository was forked from."; domain=jl.Package)
    _declare_prop!(g, jl.fundingLink, "funding link",
        "Sponsorship/funding URL declared by the repository."; domain=jl.Package)
    _declare_prop!(g, jl.hasDiscussions, "has discussions",
        "Whether GitHub Discussions are enabled."; domain=jl.Package)
    _declare_prop!(g, jl.latestReleaseTag, "latest GitHub release tag",
        "Tag name of the most recent GitHub release (may lag the registry version)."; domain=jl.Package)
    _declare_prop!(g, jl.latestReleaseDate, "latest GitHub release date",
        "Publication date of the most recent GitHub release."; domain=jl.Package)

    # ── People ──
    _declare_prop!(g, jl.commits, "commit count",
        "Annotation on a dcterms:contributor statement: number of commits that person made to that package's repository.")
    _declare_prop!(g, jl.followers, "GitHub followers",
        "Follower count of a GitHub user."; domain=foaf.Person)

    # ── Snapshot properties (named snapshot graphs) ──
    _declare_prop!(g, jl.observedAt, "observed at",
        "Date this snapshot was taken."; domain=jl.PackageSnapshot)
    _declare_prop!(g, jl.forPackage, "for package",
        "Package this snapshot describes."; domain=jl.PackageSnapshot, range=jl.Package)
    _declare_prop!(g, jl.hasPackageSnapshot, "has package snapshot",
        "Links the ecosystem snapshot to each per-package snapshot.";
        domain=jl.Snapshot, range=jl.PackageSnapshot)
    for (prop, label, comment) in [
        (jl.stars,             "stars",              "GitHub stargazer count."),
        (jl.forks,             "forks",              "GitHub fork count."),
        (jl.watchers,          "watchers",           "GitHub watcher count."),
        (jl.openIssues,        "open issues",        "Open issue count."),
        (jl.closedIssues,      "closed issues",      "Closed issue count."),
        (jl.mergedPRs,         "merged pull requests", "Merged pull-request count."),
        (jl.commitCount,       "commit count",       "Total commits on the default branch."),
        (jl.releaseCount,      "release count",      "Number of GitHub releases."),
        (jl.monthlyDownloads,  "monthly downloads",  "Package downloads in the last month (juliapkgstats.com)."),
        (jl.contributorCount,  "contributor count",  "Number of human contributors (capped at 300)."),
        (jl.isArchived,        "is archived",        "Whether the repository is archived."),
        (jl.lastPushedAt,      "last pushed at",     "Timestamp of the most recent push."),
        (jl.diskUsageKb,       "disk usage (KB)",    "Repository size in kilobytes."),
        (jl.pagerank,          "dependency PageRank", "PageRank over the jl:dependsOn graph — load-bearing packages score high."),
        (jl.directDependents,  "direct dependents",  "Number of packages whose latest version depends directly on this one."),
        (jl.transitiveDependents, "transitive dependents", "Number of distinct packages that depend on this one directly or indirectly — its dependency-graph blast radius."),
    ]
        _declare_prop!(g, prop, label, comment; domain=jl.PackageSnapshot)
    end

    g
end
