# Compute layer for the ecosystem-insights notebook.
# include("graphtools.jl") once in the setup cell.
#
# Two rules learned the hard way:
#  * Per-package contributor/commit lookups use RDF.jl's match() term API,
#    NOT SPARQL rdf:reifies queries — the latter do an unbound-subject scan
#    that takes minutes.
#  * The heavy structures (digraph, per-package records, trust surface) are
#    built ONCE here so the narrative cells and the OJS export stay cheap.

using RDF, Graphs, DataFrames
import JSON

const JL      = Namespace("https://julia-ecosystem.org/ns/")
const PKG_PRE = "https://juliahub.com/ui/Packages/General/"
const GH_PRE  = "https://github.com/"
const P_CONTRIB = IRI("http://purl.org/dc/terms/contributor")
const P_REIFIES = IRI("http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies")
const P_COMMITS = JL.commits

# Julia standard libraries ship with Julia; they're registered but not
# independently "chosen" dependencies. Computed from the running Julia so it
# tracks the reader's version.
const STDLIBS = Set(readdir(Sys.STDLIB))
isstdlib(name) = name in STDLIBS

const PROLOGUE = """
PREFIX jl: <https://julia-ecosystem.org/ns/>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX dcterms: <http://purl.org/dc/terms/>
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
PREFIX sdo: <https://schema.org/>
PREFIX schema: <https://schema.org/>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
"""

_lit(x) = x === nothing ? missing :
          x isa Literal ? value(x) :
          x isa IRI ? x.value : string(x)

function q(ds, body::AbstractString)
    sol = sparql(ds, PROLOGUE * body)
    df = DataFrame()
    for c in sol.variables
        df[!, c] = [_lit(row[c]) for row in sol]
    end
    df
end
scalar(ds, body) = (df = q(ds, body); nrow(df) == 0 ? missing : df[1, 1])

pkgname(iri) = replace(String(iri), PKG_PRE => "")
ghlogin(iri) = replace(String(iri), GH_PRE => "")
pkg_iri(name) = IRI(PKG_PRE * name)

juliahub_link(name) = "[`$name`](https://juliahub.com/ui/Packages/General/$name)"
github_link(login)  = "[$login](https://github.com/$login)"
fmt_int(n) = ismissing(n) ? "—" : replace(string(round(Int, n)), r"(?<=\d)(?=(\d{3})+$)" => ",")

# Data bridge to the client. Writes `data` as `window.__DATA_<name>` into a
# sidecar `<name>.js` file and emits a <script src> tag; Quarto's
# embed-resources step inlines the file into the self-contained HTML. This
# routes around two dead ends: ojs_define doesn't work under the Jupyter
# Julia engine, and large payloads printed to the cell's output stream are
# silently dropped by Jupyter's iopub rate limit (~a few hundred KB). OJS
# cells then read `window.__DATA_<name>` directly.
function embed_json(name::AbstractString, data)
    fname = name * ".js"
    open(fname, "w") do io
        write(io, "window.__DATA_", name, " = ")
        JSON.print(io, data)
        write(io, ";")
    end
    println("<script src=\"", fname, "\"></script>")
end

const CONTRIB_CAVEAT = """
*These are credits, not a ranking of worth. Commit count reflects code
commits only — not code review, issue triage, documentation, or design —
and a GitHub account may not map one-to-one to a person (handle renames,
shared or organizational accounts).*
"""

# ── Per-package contributor lookup (fast term-API path) ──────────────────────

"Vector of (login, commits) for a package, descending. High-volume CI bots are
already filtered at collection time (see contributors.jl KNOWN_BOTS); automated
and AI-authored accounts that remain in the data are kept, for transparency."
function contributors_of(g::RDF.Graph, name::AbstractString)
    out = Tuple{String,Int}[]
    for t in match(g; subject=pkg_iri(name), predicate=P_CONTRIB)
        t.object isa IRI || continue
        login = ghlogin(t.object.value)
        n = 0
        tt = TripleTerm(t.subject, t.predicate, t.object)
        for rt in match(g; predicate=P_REIFIES, object=tt)
            for at in match(g; subject=rt.subject, predicate=P_COMMITS)
                n = Int(value(at.object))
            end
        end
        push!(out, (login, n))
    end
    sort!(out; by=last, rev=true)
end

# ── Dependency digraph + trust surface ───────────────────────────────────────

"""
Build the dependency digraph and per-package integer contributor sets, then
compute the 'trust surface': for each package, the number of distinct
contributor accounts across its entire transitive hard-dependency closure
(including itself). Uses SCC condensation + reverse-topo BitSet DP so it's
exact and fast even with dependency cycles.
Returns a Dict{String,Int} name → trust-surface count.
"""
function trust_surface(ds)
    g = ds.default_graph
    # index packages
    names = q(ds, "SELECT ?name WHERE { ?p a jl:Package ; rdfs:label ?name }").name
    idx = Dict{String,Int}(n => i for (i, n) in enumerate(names))
    N = length(names)

    # dependency edges (name → name), skip stdlib/self handled naturally
    dg = SimpleDiGraph(N)
    deprows = q(ds, "SELECT ?a ?b WHERE { ?x jl:dependsOn ?y . ?x rdfs:label ?a . ?y rdfs:label ?b }")
    for r in eachrow(deprows)
        (haskey(idx, r.a) && haskey(idx, r.b)) || continue
        add_edge!(dg, idx[r.a], idx[r.b])
    end

    # per-package contributor id sets
    people = Dict{String,Int}(); pid = 0
    contribsets = [BitSet() for _ in 1:N]
    for t in match(g; predicate=P_CONTRIB)
        (t.subject isa IRI && t.object isa IRI) || continue
        nm = pkgname(t.subject.value)
        haskey(idx, nm) || continue
        login = ghlogin(t.object.value)
        p = get!(people, login) do; pid += 1; end
        push!(contribsets[idx[nm]], p)
    end

    # condensation (DAG of SCCs), union contributor sets within each SCC
    sccs = strongly_connected_components(dg)
    comp_of = Vector{Int}(undef, N)
    for (ci, comp) in enumerate(sccs), v in comp
        comp_of[v] = ci
    end
    C = length(sccs)
    cond = SimpleDiGraph(C)
    for e in edges(dg)
        cu, cv = comp_of[src(e)], comp_of[dst(e)]
        cu == cv || add_edge!(cond, cu, cv)
    end
    compset = [BitSet() for _ in 1:C]
    for v in 1:N
        union!(compset[comp_of[v]], contribsets[v])
    end

    # reverse-topo DP: closure(c) = compset[c] ∪ closure(children)
    order = topological_sort_by_dfs(cond)          # u before v when u→v
    closure = [BitSet() for _ in 1:C]
    for c in reverse(order)
        acc = copy(compset[c])
        for w in outneighbors(cond, c)
            union!(acc, closure[w])
        end
        closure[c] = acc
    end

    Dict(names[v] => length(closure[comp_of[v]]) for v in 1:N)
end

# ── Data payloads for the client (OJS) ───────────────────────────────────────

"""
Build the k-core dependency network for the interactive graph (§5).
Non-JLL packages only. Raises k until the node count is ≤ maxnodes so the
force layout stays smooth. Returns (nodes, links, k) where nodes carry
name/group(community)/pr/dependents and links are source/target index pairs.
"""
function network_data(ds; kstart=5, maxnodes=700)
    # non-JLL, non-stdlib package name set (stdlib coverage in the registry is
    # partial, so including it would show some stdlibs but not others)
    keep = Set(String(n) for n in
               q(ds, "SELECT ?name WHERE { ?p a jl:Package ; rdfs:label ?name . FILTER NOT EXISTS { ?p jl:isJLL true } }").name
               if !isstdlib(String(n)))
    names = collect(keep)
    idx = Dict(n => i for (i, n) in enumerate(names))
    N = length(names)
    N == 0 && return (nodes=Dict{String,Any}[], links=Dict{String,Int}[], k=kstart)
    dg = SimpleDiGraph(N)
    for r in eachrow(q(ds, "SELECT ?a ?b WHERE { ?x jl:dependsOn ?y . ?x rdfs:label ?a . ?y rdfs:label ?b }"))
        (haskey(idx, r.a) && haskey(idx, r.b)) || continue
        add_edge!(dg, idx[r.a], idx[r.b])
    end
    ug = SimpleGraph(dg)                       # k-core is undirected
    ne(ug) == 0 && return (nodes=Dict{String,Any}[], links=Dict{String,Int}[], k=kstart)

    local core, k
    k = kstart
    while true
        core = k_core(ug, k)
        (length(core) <= maxnodes || k > 40) && break
        k += 1
    end
    coreset = Set(core)

    # communities via label propagation on the induced subgraph
    sub, vmap = induced_subgraph(ug, collect(core))    # vmap: sub idx → orig idx
    labels = label_propagation(sub)[1]

    prmap = Dict(r.name => Float64(r.v) for r in eachrow(snapmetric_ds(ds, "pagerank")))
    depmap = Dict(r.name => Int(r.v) for r in eachrow(snapmetric_ds(ds, "directDependents")))

    orig2sub = Dict(v => i for (i, v) in enumerate(vmap))
    nodes = [Dict(
        "id" => names[v],
        "name" => names[v],
        "group" => labels[orig2sub[v]],
        "pr" => get(prmap, names[v], 0.0),
        "dependents" => get(depmap, names[v], 0),
    ) for v in core]

    nodeidx = Dict(names[v] => (i-1) for (i, v) in enumerate(core))  # 0-based for JS
    links = Dict{String,Int}[]
    for e in edges(dg)
        (src(e) in coreset && dst(e) in coreset) || continue
        push!(links, Dict("source" => nodeidx[names[src(e)]], "target" => nodeidx[names[dst(e)]]))
    end
    (nodes=nodes, links=links, k=k)
end

# snapshot metric as name→value DataFrame (module-level so network_data can use it)
snapmetric_ds(ds, pred) = q(ds, """
  SELECT ?name ?v WHERE {
    GRAPH ?g { ?s jl:forPackage ?pkg ; jl:$pred ?v . }
    ?pkg rdfs:label ?name .
  }""")

"""
Compact per-package records for the explorer (§6), one per package.
Lists are capped so the embedded JSON stays a few MB. `ts` is the
precomputed trust-surface Dict from trust_surface(ds).
"""
function package_index(ds, ts; dep_cap=30, contrib_cap=10)
    g = ds.default_graph
    # scalar snapshot metrics → Dicts
    metrics = Dict{String,Dict{String,Any}}()
    getrec(n) = get!(() -> Dict{String,Any}(), metrics, n)
    for pred in ("stars", "directDependents", "transitiveDependents", "monthlyDownloads", "contributorCount")
        for r in eachrow(snapmetric_ds(ds, pred))
            getrec(String(r.name))[pred] = Int(r.v)
        end
    end
    # static fields
    for r in eachrow(q(ds, "SELECT ?name ?v WHERE { ?p rdfs:label ?name ; jl:latestVersion ?v }"))
        getrec(String(r.name))["version"] = String(r.v)
    end
    for r in eachrow(q(ds, "SELECT ?name ?l WHERE { ?p rdfs:label ?name ; dcterms:license ?lic . ?lic rdfs:label ?l }"))
        getrec(String(r.name))["license"] = String(r.l)
    end
    # dependency lists (both directions)
    deps = Dict{String,Vector{String}}(); depnts = Dict{String,Vector{String}}()
    for r in eachrow(q(ds, "SELECT ?a ?b WHERE { ?x jl:dependsOn ?y . ?x rdfs:label ?a . ?y rdfs:label ?b }"))
        push!(get!(() -> String[], deps, String(r.a)), String(r.b))
        push!(get!(() -> String[], depnts, String(r.b)), String(r.a))
    end

    allnames = q(ds, "SELECT ?name WHERE { ?p a jl:Package ; rdfs:label ?name }").name
    records = Vector{Dict{String,Any}}()
    for name in allnames
        name = String(name)
        m = get(metrics, name, Dict{String,Any}())
        contribs = contributors_of(g, name)
        d  = sort(get(deps, name, String[]))
        dn = get(depnts, name, String[])
        push!(records, Dict(
            "name" => name,
            "stars" => get(m, "stars", nothing),
            "dependents" => get(m, "directDependents", length(dn)),
            "transitive" => get(m, "transitiveDependents", nothing),
            "requests" => get(m, "monthlyDownloads", nothing),
            "contributors" => get(m, "contributorCount", length(contribs)),
            "version" => get(m, "version", nothing),
            "license" => get(m, "license", nothing),
            "trust" => get(ts, name, nothing),
            "isstdlib" => isstdlib(name),
            "deps" => first(d, min(dep_cap, length(d))),
            "ndeps" => length(d),
            "dependents_list" => first(sort(dn), min(dep_cap, length(dn))),
            "top_contributors" => [Dict("login" => l, "commits" => c)
                                   for (l, c) in first(contribs, min(contrib_cap, length(contribs)))],
        ))
    end
    records
end
