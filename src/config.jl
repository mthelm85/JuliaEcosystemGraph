# ── Namespaces ────────────────────────────────────────────────────────────────
#
# Ontology terms live in the jl: namespace.  Entity IRIs are minted against
# real, dereferenceable URL schemes (JuliaHub package pages, GitHub profiles
# and topic pages, SPDX license pages) so every node in the graph points at an
# actual web resource.

const jl  = Namespace("https://julia-ecosystem.org/ns/")
const sdo = Namespace("https://schema.org/")          # terms missing from RDF.schema
const sh  = Namespace("http://www.w3.org/ns/shacl#")

const PKG_BASE   = "https://juliahub.com/ui/Packages/General/"
const SNAP_BASE  = "https://julia-ecosystem.org/snapshots/"
const GH_BASE    = "https://github.com/"
const TOPIC_BASE = "https://github.com/topics/"
const SPDX_BASE  = "https://spdx.org/licenses/"

const DCTERMS_LICENSE_DOC = IRI("http://purl.org/dc/terms/LicenseDocument")

# Julia standard libraries shipping with this Julia. Some (≈35 of 61) are also
# registered in General and therefore appear as package nodes; this set flags
# them with jl:isStdlib so queries can exclude them consistently.
const STDLIBS = Set(readdir(Sys.STDLIB))

pkg_iri(name::AbstractString)          = IRI(PKG_BASE * name)
gh_actor_iri(login::AbstractString)    = IRI(GH_BASE * login)
topic_iri(t::AbstractString)           = IRI(TOPIC_BASE * t)
spdx_iri(id::AbstractString)           = IRI(SPDX_BASE * id)
snapshot_iri(date::AbstractString)     = IRI(SNAP_BASE * date)
pkg_snapshot_iri(date::AbstractString, name::AbstractString) =
    IRI(SNAP_BASE * date * "/" * name)

# ── Configuration ─────────────────────────────────────────────────────────────

Base.@kwdef struct Config
    token::String
    out_dir::String            = "out"
    out_file::String           = "julia_ecosystem.nq"
    snapshot_date::String      = Dates.format(today(), "yyyy-mm-dd")
    limit::Int                 = 0     # 0 = all packages (PKG_LIMIT caps for smoke tests)
    gh_batch::Int              = 15    # repos per GraphQL request
    dl_concurrent::Int         = 20    # concurrent juliapkgstats requests
    min_pkgs_for_enrichment::Int = 3   # fetch full profiles for people on ≥ N packages
    max_contributor_pages::Int = 10    # 100 contributors per page
    checkpoint_every::Int      = 200   # repos between checkpoint saves
end

function config_from_env()
    token = get(ENV, "GITHUB_TOKEN", "")
    isempty(token) && error("GITHUB_TOKEN environment variable is not set")
    limit = parse(Int, get(ENV, "PKG_LIMIT", "0"))
    # Smoke runs get their own output area so they never clobber a real build
    default_dir  = limit > 0 ? "out_smoke" : "out"
    default_file = limit > 0 ? "julia_ecosystem_smoke.nq" : "julia_ecosystem.nq"
    Config(
        token    = token,
        limit    = limit,
        out_dir  = get(ENV, "KG_OUT_DIR", default_dir),
        out_file = get(ENV, "KG_OUT_FILE", default_file),
        # KG_SNAPSHOT_DATE pins the snapshot date. Set it when re-deriving an
        # existing graph so an advanced machine clock doesn't mint a second,
        # partial snapshot instead of updating the existing one.
        snapshot_date = get(ENV, "KG_SNAPSHOT_DATE", Dates.format(today(), "yyyy-mm-dd")),
    )
end

# ── Shared snapshot-node helper ───────────────────────────────────────────────
#
# Every phase that writes time-varying metrics emits the same core triples for
# a package's snapshot node.  Graphs are sets, so duplicates merge away.

function snapshot_core!(g::Graph, cfg::Config, pkg_name::AbstractString)::IRI
    snap = pkg_snapshot_iri(cfg.snapshot_date, pkg_name)
    push!(g, Triple(snap, rdf.type, jl.PackageSnapshot))
    push!(g, Triple(snap, jl.forPackage, pkg_iri(pkg_name)))
    push!(g, Triple(snap, jl.observedAt, Literal(Date(cfg.snapshot_date))))
    push!(g, Triple(snapshot_iri(cfg.snapshot_date), jl.hasPackageSnapshot, snap))
    snap
end

# Parse GitHub's ISO-8601 timestamps ("2026-07-19T12:34:56Z") to DateTime.
function gh_datetime(s)::Union{DateTime,Nothing}
    str = string(s)
    isempty(str) && return nothing
    try
        DateTime(chopsuffix(str, "Z"))
    catch
        nothing
    end
end

# Only mint IRIs from strings that are plausibly valid absolute URLs.
function try_url_iri(s)::Union{IRI,Nothing}
    str = strip(string(s))
    (startswith(str, "http://") || startswith(str, "https://")) || return nothing
    (occursin(' ', str) || occursin('<', str) || occursin('>', str)) && return nothing
    try
        IRI(str)
    catch
        nothing
    end
end
