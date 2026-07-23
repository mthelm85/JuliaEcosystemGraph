# ── Final assembly ────────────────────────────────────────────────────────────
#
# Merge the phase graphs into one Dataset:
#   default graph  — ontology + registry + GitHub static + contributors + users
#   named graph    — this date's snapshot metrics (plus derived network stats)
# Snapshot graphs from previous builds of the output file are carried
# forward, so re-running on later dates accumulates a time series.

function assemble(cfg::Config)
    println("\n=== Assemble & validate ===")

    default_g = Graph()
    build_ontology!(default_g)
    for name in ("registry", "github_static", "contributors", "users")
        merge!(default_g, load_graph(cfg, name))
    end

    snap_g = Graph()
    for name in ("github_snapshot", "contributors_snapshot", "downloads")
        merge!(snap_g, load_graph(cfg, name))
    end

    add_derived!(snap_g, default_g, cfg)

    hub = snapshot_iri(cfg.snapshot_date)
    push!(snap_g, Triple(hub, rdf.type, jl.Snapshot))
    push!(snap_g, Triple(hub, jl.observedAt, Literal(Date(cfg.snapshot_date))))

    ds = Dataset(; default_graph=default_g)
    if isfile(cfg.out_file)
        old = rdf_read(cfg.out_file)
        if old isa Dataset
            kept = 0
            for (name, g) in old.named_graphs
                name == hub && continue
                ds[name] = g
                kept += 1
            end
            kept > 0 && println("  carried forward $kept prior snapshot graph(s)")
        end
    end
    ds[hub] = snap_g

    warns = validate(ds)
    isempty(warns) ? println("  RDF validation: clean") :
        println("  RDF validation: $(length(warns)) warning(s)")

    union_g = Graph()
    merge!(union_g, default_g)
    merge!(union_g, snap_g)
    rep = validate_shapes(union_g, build_shapes())
    if rep.conforms
        println("  SHACL validation: conforms")
    else
        println("  SHACL validation: $(length(rep.results)) violation(s) — first few:")
        for r in Iterators.take(rep.results, 5)
            println("    ", r)
        end
    end

    tmp = cfg.out_file * ".tmp"
    rdf_write(tmp, ds)                  # non-.jsonld extension → N-Quads
    mv(tmp, cfg.out_file; force=true)

    @printf("\nDone — %d triples | %d snapshot graph(s) | %s\n",
            ntriples(ds), length(ds.named_graphs), cfg.out_file)
    ds
end
