# ── Phase 3: Contributors (GitHub REST) ───────────────────────────────────────
#
# The long phase: one paced REST request per repository (a few more for repos
# with >100 contributors), ~3.5 hours for the full ecosystem.  Produces the
# cross-package people graph:
#
#   <pkg> dcterms:contributor <https://github.com/login> .
#     — annotated (RDF 1.2 reification) with jl:commits <n>
#   <person> a foaf:Person ; foaf:nick "login" .
#
# plus per-package jl:contributorCount in the snapshot graph.

# Automation accounts registered as regular users, so the "[bot]" suffix and
# type == "Bot" checks miss them.  They'd otherwise top every
# cross-package-contributor query.
const KNOWN_BOTS = Set([
    "JuliaTagBot", "JuliaRegistrator", "jlbuild", "femtocleaner",
    "github-actions", "dependabot", "dependabot-preview",
    "CompatHelper", "greenkeeper", "renovate", "allcontributors",
])

function fetch_contributors(client::GHClient, owner, repo, max_pages::Int)
    out = Tuple{String,Int}[]
    for page in 1:max_pages
        data = rest_get(client, "/repos/$owner/$repo/contributors?per_page=100&page=$page")
        data isa AbstractVector || break     # 404 / error / empty repo
        for c in data
            get(c, "type", "") == "User" || continue          # drop bots + anonymous
            login = _nonempty_str(get(c, "login", nothing))
            isnothing(login) && continue
            (endswith(login, "[bot]") || login in KNOWN_BOTS) && continue
            push!(out, (login, Int(get(c, "contributions", 0))))
        end
        length(data) < 100 && break
    end
    out
end

function fetch_all_contributors!(cfg::Config, client::GHClient, st::BuildState,
                                 pkgs::Vector{PkgInfo})
    repos   = unique_github_repos(pkgs)
    done    = done_set(st, "contributors")
    pending = sort!([k for k in keys(repos) if k ∉ done])

    gmain = load_graph(cfg, "contributors")
    gsnap = load_graph(cfg, "contributors_snapshot")

    # People already typed in a previous partial run (avoid re-pushing is not
    # required for correctness — graphs are sets — but skip the string work)
    seen_people = Set{String}()
    for t in match(gmain; predicate=foaf.nick)
        push!(seen_people, string(value(t.object)))
    end

    total = length(pending)
    isempty(done) || println("  resuming: $(length(done)) repos already fetched, $total remaining")
    total == 0 && return

    est_h = round(total * client.min_interval / 3600; digits=1)
    println("  fetching contributors for $total repos (~$(est_h)h at current pacing)")

    processed   = 0
    done_buffer = String[]

    checkpoint = function ()
        save_graph(cfg, "contributors", gmain)
        save_graph(cfg, "contributors_snapshot", gsnap)
        mark_done!(st, "contributors", done_buffer)
        empty!(done_buffer)
    end

    for key in pending
        owner, repo = split(key, '/')
        contribs = fetch_contributors(client, owner, repo, cfg.max_contributor_pages)

        for p in repos[key]
            iri = pkg_iri(p.name)
            for (login, n) in contribs
                person = gh_actor_iri(login)
                annotate!(gmain, Triple(iri, dcterms.contributor, person), jl.commits, n)
                if login ∉ seen_people
                    push!(gmain, Triple(person, rdf.type, foaf.Person))
                    push!(gmain, Triple(person, foaf.nick, Literal(login)))
                    push!(seen_people, login)
                end
            end
            snap = snapshot_core!(gsnap, cfg, p.name)
            push!(gsnap, Triple(snap, jl.contributorCount, Literal(length(contribs))))
        end

        push!(done_buffer, key)
        processed += 1
        if length(done_buffer) >= cfg.checkpoint_every || processed == total
            checkpoint()
            @printf("  contributors: %d / %d (checkpoint saved)\n", processed, total)
        end
    end

    isempty(done_buffer) || checkpoint()
    println("  contributor graph: $(length(gmain)) triples, $(length(seen_people)) people")
end
