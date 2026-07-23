# ── Phase 4: User profile enrichment (GitHub REST) ────────────────────────────
#
# People contributing to ≥ cfg.min_pkgs_for_enrichment packages get their
# public profile attached: real name, employer, location, follower count.
# These are the connective tissue of the ecosystem, so the extra requests
# (one per person, ~1 hour) buy a lot of query power.

function select_enrichment_logins(gmain::Graph, min_pkgs::Int)::Vector{String}
    counts = Dict{String,Int}()
    for t in match(gmain; predicate=dcterms.contributor)
        t.object isa IRI || continue
        login = String(chopprefix(t.object.value, GH_BASE))
        counts[login] = get(counts, login, 0) + 1
    end
    sort!([l for (l, c) in counts if c >= min_pkgs])
end

function enrich_users!(cfg::Config, client::GHClient, st::BuildState)
    gmain  = load_graph(cfg, "contributors")
    logins = select_enrichment_logins(gmain, cfg.min_pkgs_for_enrichment)

    done    = done_set(st, "users")
    pending = [l for l in logins if l ∉ done]

    gusers = load_graph(cfg, "users")

    total = length(pending)
    isempty(done) || println("  resuming: $(length(done)) profiles already fetched, $total remaining")
    println("  enriching $total people (≥$(cfg.min_pkgs_for_enrichment) packages each)")
    total == 0 && return

    processed   = 0
    done_buffer = String[]

    checkpoint = function ()
        save_graph(cfg, "users", gusers)
        mark_done!(st, "users", done_buffer)
        empty!(done_buffer)
    end

    for login in pending
        data = rest_get(client, "/users/$login")
        if data isa AbstractDict
            person = gh_actor_iri(login)

            name = _nonempty_str(get(data, "name", nothing))
            isnothing(name) || push!(gusers, Triple(person, foaf.name, Literal(name)))

            company = _nonempty_str(get(data, "company", nothing))
            isnothing(company) ||
                push!(gusers, Triple(person, schema.worksFor, Literal(lstrip(company, '@'))))

            location = _nonempty_str(get(data, "location", nothing))
            isnothing(location) || push!(gusers, Triple(person, sdo.location, Literal(location)))

            followers = get(data, "followers", nothing)
            isnothing(followers) ||
                push!(gusers, Triple(person, jl.followers, Literal(Int(followers))))
        end

        push!(done_buffer, login)
        processed += 1
        if length(done_buffer) >= cfg.checkpoint_every || processed == total
            checkpoint()
            @printf("  users: %d / %d (checkpoint saved)\n", processed, total)
        end
    end

    isempty(done_buffer) || checkpoint()
    println("  user profiles: $(length(gusers)) triples")
end
