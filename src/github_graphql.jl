# ── Phase 2: GitHub repository metadata (GraphQL) ────────────────────────────
#
# Batched aliased queries (cfg.gh_batch repos per request).  Stable facts go
# to the static graph (github_static.nt → default graph); counts and other
# time-varying metrics go to the snapshot graph (github_snapshot.nt).
# Monorepos are fetched once per repository and emitted per package.

# "owner/repo" → packages living in that repository
function unique_github_repos(pkgs::Vector{PkgInfo})
    repos = Dict{String,Vector{PkgInfo}}()
    for p in pkgs
        isnothing(p.owner) && continue
        push!(get!(() -> PkgInfo[], repos, "$(p.owner)/$(p.reponame)"), p)
    end
    repos
end

function gh_repo_query(batch)
    aliases = join(map(enumerate(batch)) do (i, (owner, name))
        ow, nm = JSON.json(owner), JSON.json(name)
        """r$i: repository(owner: $ow, name: $nm) {
            description homepageUrl createdAt pushedAt isArchived isFork
            diskUsage hasDiscussionsEnabled stargazerCount forkCount
            watchers { totalCount }
            openIssues: issues(states: OPEN) { totalCount }
            closedIssues: issues(states: CLOSED) { totalCount }
            mergedPRs: pullRequests(states: MERGED) { totalCount }
            primaryLanguage { name }
            licenseInfo { spdxId }
            owner { __typename }
            parent { url }
            fundingLinks { url }
            latestRelease { tagName publishedAt }
            releases { totalCount }
            defaultBranchRef { target { ... on Commit { history { totalCount } } } }
            repositoryTopics(first: 20) { nodes { topic { name } } }
        }"""
    end, "\n")
    "{ $aliases\nrateLimit { cost remaining resetAt } }"
end

# Safe nested lookup through JSON dicts: _dig(d, "a", "b") == d["a"]["b"] | nothing
function _dig(x, keys...)
    for k in keys
        x isa AbstractDict || return nothing
        x = get(x, k, nothing)
        isnothing(x) && return nothing
    end
    x
end

_nonempty_str(x) = (s = string(something(x, "")); isempty(strip(s)) ? nothing : String(strip(s)))

function emit_repo!(gstat::Graph, gsnap::Graph, cfg::Config,
                    repo_pkgs::Vector{PkgInfo}, rd::AbstractDict)
    owner_login = repo_pkgs[1].owner
    owner_type  = _dig(rd, "owner", "__typename")
    owner_iri   = gh_actor_iri(owner_login)
    if owner_type == "Organization"
        push!(gstat, Triple(owner_iri, rdf.type, foaf.Organization))
    elseif owner_type == "User"
        push!(gstat, Triple(owner_iri, rdf.type, foaf.Person))
        # Owners typed as people need the same nick contributors get — not
        # every repo owner appears in their own contributor list
        push!(gstat, Triple(owner_iri, foaf.nick, Literal(owner_login)))
    end
    push!(gstat, Triple(owner_iri, rdfs.label, Literal(owner_login)))

    for p in repo_pkgs
        iri = pkg_iri(p.name)

        # ── Static facts → default graph ──
        desc = _nonempty_str(get(rd, "description", nothing))
        isnothing(desc) || push!(gstat, Triple(iri, schema.description, Literal(desc)))

        home = try_url_iri(something(get(rd, "homepageUrl", nothing), ""))
        isnothing(home) || push!(gstat, Triple(iri, schema.url, home))

        created = gh_datetime(something(get(rd, "createdAt", nothing), ""))
        isnothing(created) || push!(gstat, Triple(iri, dcterms.created, Literal(created)))

        lang = _nonempty_str(_dig(rd, "primaryLanguage", "name"))
        isnothing(lang) || push!(gstat, Triple(iri, sdo.programmingLanguage, Literal(lang)))

        spdx = _nonempty_str(_dig(rd, "licenseInfo", "spdxId"))
        if !isnothing(spdx) && spdx != "NOASSERTION"
            lic = spdx_iri(spdx)
            push!(gstat, Triple(iri, dcterms.license, lic))
            push!(gstat, Triple(lic, rdf.type, DCTERMS_LICENSE_DOC))
            push!(gstat, Triple(lic, rdfs.label, Literal(spdx)))
        end

        if get(rd, "isFork", false) === true
            push!(gstat, Triple(iri, jl.isFork, Literal(true)))
            parent = try_url_iri(something(_dig(rd, "parent", "url"), ""))
            isnothing(parent) || push!(gstat, Triple(iri, jl.forkParent, parent))
        end

        links = get(rd, "fundingLinks", nothing)
        if links isa AbstractVector
            for fl in links
                u = try_url_iri(something(_dig(fl, "url"), ""))
                isnothing(u) || push!(gstat, Triple(iri, jl.fundingLink, u))
            end
        end

        get(rd, "hasDiscussionsEnabled", false) === true &&
            push!(gstat, Triple(iri, jl.hasDiscussions, Literal(true)))

        tag = _nonempty_str(_dig(rd, "latestRelease", "tagName"))
        isnothing(tag) || push!(gstat, Triple(iri, jl.latestReleaseTag, Literal(tag)))
        reldate = gh_datetime(something(_dig(rd, "latestRelease", "publishedAt"), ""))
        isnothing(reldate) || push!(gstat, Triple(iri, jl.latestReleaseDate, Literal(reldate)))

        topics = _dig(rd, "repositoryTopics", "nodes")
        if topics isa AbstractVector
            for node in topics
                tname = _nonempty_str(_dig(node, "topic", "name"))
                isnothing(tname) && continue
                t = topic_iri(tname)
                push!(gstat, Triple(iri, dcterms.subject, t))
                push!(gstat, Triple(t, rdf.type, skos.Concept))
                push!(gstat, Triple(t, skos.prefLabel, Literal(tname)))
            end
        end

        # ── Time-varying metrics → snapshot graph ──
        snap = snapshot_core!(gsnap, cfg, p.name)
        push!(gsnap, Triple(snap, jl.stars, Literal(Int(get(rd, "stargazerCount", 0)))))
        push!(gsnap, Triple(snap, jl.forks, Literal(Int(get(rd, "forkCount", 0)))))
        push!(gsnap, Triple(snap, jl.isArchived, Literal(get(rd, "isArchived", false) === true)))

        for (pred, path) in [
            (jl.watchers,     ("watchers", "totalCount")),
            (jl.openIssues,   ("openIssues", "totalCount")),
            (jl.closedIssues, ("closedIssues", "totalCount")),
            (jl.mergedPRs,    ("mergedPRs", "totalCount")),
            (jl.releaseCount, ("releases", "totalCount")),
            (jl.commitCount,  ("defaultBranchRef", "target", "history", "totalCount")),
        ]
            v = _dig(rd, path...)
            isnothing(v) || push!(gsnap, Triple(snap, pred, Literal(Int(v))))
        end

        pushed = gh_datetime(something(get(rd, "pushedAt", nothing), ""))
        isnothing(pushed) || push!(gsnap, Triple(snap, jl.lastPushedAt, Literal(pushed)))

        disk = get(rd, "diskUsage", nothing)
        isnothing(disk) || push!(gsnap, Triple(snap, jl.diskUsageKb, Literal(Int(disk))))
    end
end

function fetch_github!(cfg::Config, client::GHClient, st::BuildState,
                       pkgs::Vector{PkgInfo})
    repos = unique_github_repos(pkgs)
    done  = done_set(st, "github")
    pending = sort!([k for k in keys(repos) if k ∉ done])

    gstat = load_graph(cfg, "github_static")
    gsnap = load_graph(cfg, "github_snapshot")

    total = length(pending)
    isempty(done) || println("  resuming: $(length(done)) repos already fetched, $total remaining")
    total == 0 && return

    processed   = 0
    done_buffer = String[]

    checkpoint = function ()
        save_graph(cfg, "github_static", gstat)
        save_graph(cfg, "github_snapshot", gsnap)
        mark_done!(st, "github", done_buffer)
        empty!(done_buffer)
    end

    for batch_keys in Iterators.partition(pending, cfg.gh_batch)
        batch = [(split(k, '/')[1], split(k, '/')[2]) for k in batch_keys]
        data  = graphql(client, gh_repo_query(batch))

        if isnothing(data)
            @warn "batch returned no data — $(length(batch_keys)) repos skipped this run"
        else
            for (i, key) in enumerate(batch_keys)
                rd = get(data, "r$i", nothing)
                rd isa AbstractDict && emit_repo!(gstat, gsnap, cfg, repos[key], rd)
                push!(done_buffer, key)   # NOT_FOUND repos are done too
            end
        end

        processed += length(batch_keys)
        if length(done_buffer) >= cfg.checkpoint_every || processed >= total
            checkpoint()
            @printf("  github: %d / %d (checkpoint saved)\n", processed, total)
        end
    end

    isempty(done_buffer) || checkpoint()
    println("  github metadata: $(length(gstat)) static + $(length(gsnap)) snapshot triples")
end
