# ── Orchestrator ──────────────────────────────────────────────────────────────

const ALL_PHASES = [:registry, :github, :downloads, :contributors, :users, :assemble]

"""
    build(; phases=Symbol[])

Run the knowledge-graph pipeline.  With no arguments every phase runs (each
network phase resumes from its checkpoint and is skipped entirely once
complete for today's snapshot date).  Pass a subset like
`build(phases=[:registry, :assemble])` to run specific phases.

Environment:
  GITHUB_TOKEN   required — classic or fine-grained token, public repo scope
  PKG_LIMIT      cap the package set for smoke tests (writes to out_smoke/)
  KG_OUT_DIR     checkpoint/working directory   (default: out/)
  KG_OUT_FILE    final N-Quads file             (default: julia_ecosystem.nq)
"""
function build(; phases::Vector{Symbol}=Symbol[])
    bad = setdiff(phases, ALL_PHASES)
    isempty(bad) || error("unknown phase(s) $bad — valid: $ALL_PHASES")
    wants(ph) = isempty(phases) || ph in phases

    cfg = config_from_env()
    mkpath(cfg.out_dir)
    st = load_state(cfg)

    @printf("Julia ecosystem knowledge graph — snapshot %s\n", cfg.snapshot_date)
    @printf("threads: %d | working dir: %s | output: %s\n",
            Threads.nthreads(), cfg.out_dir, cfg.out_file)
    cfg.limit > 0 && println("PKG_LIMIT=$(cfg.limit) — smoke mode")

    println("\n=== Registry scan ===")
    pkgs = scan_registry(cfg)
    println("  $(length(pkgs)) packages")
    isempty(pkgs) && error("registry scan returned 0 packages — aborting to avoid overwriting cached data")

    if wants(:registry)
        g = registry_graph(cfg, pkgs)
        save_graph(cfg, "registry", g)
        println("  registry graph: $(length(g)) triples")
    end

    client   = GHClient(cfg.token)
    gh_repos = unique_github_repos(pkgs)
    needs_gh = (wants(:github)       && !phase_complete(st, "github")) ||
               (wants(:contributors) && !phase_complete(st, "contributors")) ||
               (wants(:users)        && !phase_complete(st, "users"))
    if needs_gh
        println("\n=== GitHub authentication ===")
        check_token(client)
    end

    if wants(:github)
        println("\n=== GitHub repository metadata (GraphQL) ===")
        if phase_complete(st, "github")
            println("  already complete — skipping")
        else
            fetch_github!(cfg, client, st, pkgs)
            # Complete only when every repo is accounted for (failed batches
            # stay pending and are retried on the next run)
            if all(k -> k in done_set(st, "github"), keys(gh_repos))
                phase_complete!(st, "github")
            else
                println("  some repos still pending — rerun to retry them")
            end
        end
    end

    if wants(:downloads)
        println("\n=== Download statistics ===")
        if phase_complete(st, "downloads")
            println("  already complete — skipping")
        else
            fetch_downloads!(cfg, st, pkgs)
            phase_complete!(st, "downloads")
        end
    end

    if wants(:contributors)
        println("\n=== Contributors (REST — the long phase) ===")
        if phase_complete(st, "contributors")
            println("  already complete — skipping")
        else
            fetch_all_contributors!(cfg, client, st, pkgs)
            all(k -> k in done_set(st, "contributors"), keys(gh_repos)) &&
                phase_complete!(st, "contributors")
        end
    end

    if wants(:users)
        println("\n=== User profile enrichment ===")
        if phase_complete(st, "users")
            println("  already complete — skipping")
        else
            enrich_users!(cfg, client, st)
            phase_complete!(st, "users")
        end
    end

    wants(:assemble) ? assemble(cfg) : nothing
end
