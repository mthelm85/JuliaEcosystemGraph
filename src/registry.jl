# ── Phase 1: General registry ─────────────────────────────────────────────────
#
# Local and fast (parallel TOML reads), so it runs fresh every build.  This is
# the source of truth for package identity: name, UUID, repo, subdir, latest
# version, dependencies, and Julia compat.

struct PkgInfo
    name::String
    uuid::String
    repo::String                       # cleaned repository URL
    subdir::Union{String,Nothing}
    owner::Union{String,Nothing}       # GitHub owner, when repo is on GitHub
    reponame::Union{String,Nothing}
    dep_names::Vector{String}
    ver_count::Int
    latest_version::String
    min_julia::Union{String,Nothing}
end

strip_git(url) = endswith(url, ".git") ? url[1:end-4] : url

function parse_github(url)
    m = Base.match(r"github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", url)
    isnothing(m) ? nothing : (owner=String(m.captures[1]), repo=String(m.captures[2]))
end

function scan_registry(cfg::Config)::Vector{PkgInfo}
    reg     = only(filter(r -> r.name == "General", Pkg.Registry.reachable_registries()))
    entries = collect(values(reg.pkgs))
    scratch = Vector{Union{PkgInfo,Nothing}}(nothing, length(entries))

    uuid_to_name = Dict(uuid => entry.name for (uuid, entry) in reg.pkgs)
    julia_uuid   = Pkg.Registry.JULIA_UUID

    Threads.@threads for i in eachindex(entries)
        e    = entries[i]
        info = try Pkg.Registry.registry_info(reg, e) catch; nothing end
        (isnothing(info) || isnothing(info.repo) || isempty(info.version_info)) && continue

        repo       = strip_git(rstrip(info.repo, '/'))
        latest_ver = maximum(keys(info.version_info))
        gh         = parse_github(repo)

        dep_names = Set{String}()
        for (vspec, deps) in info.deps
            latest_ver in vspec || continue
            for uuid in deps
                uuid == julia_uuid && continue
                name = get(uuid_to_name, uuid, nothing)
                isnothing(name) || push!(dep_names, name)
            end
        end

        min_julia = nothing
        for (vspec, compat) in info.compat
            latest_ver in vspec || continue
            spec = get(compat, julia_uuid, nothing)
            isnothing(spec) || (min_julia = string(spec); break)
        end

        subdir = isnothing(info.subdir) || isempty(info.subdir) ? nothing : String(info.subdir)

        scratch[i] = PkgInfo(
            e.name, string(e.uuid), repo, subdir,
            isnothing(gh) ? nothing : gh.owner,
            isnothing(gh) ? nothing : gh.repo,
            sort!(collect(dep_names)), length(info.version_info),
            string(latest_ver), min_julia,
        )
    end

    pkgs = sort!(PkgInfo[p for p in scratch if !isnothing(p)], by=p -> p.name)
    cfg.limit > 0 && (pkgs = pkgs[1:min(cfg.limit, length(pkgs))])
    pkgs
end

function registry_graph(cfg::Config, pkgs::Vector{PkgInfo})::Graph
    g      = Graph()
    byname = Set(p.name for p in pkgs)

    for p in pkgs
        iri = pkg_iri(p.name)
        push!(g, Triple(iri, rdf.type, jl.Package))
        push!(g, Triple(iri, rdfs.label, Literal(p.name)))
        push!(g, Triple(iri, dcterms.identifier, Literal(p.uuid)))
        push!(g, Triple(iri, jl.versionCount, Literal(p.ver_count)))
        push!(g, Triple(iri, jl.latestVersion, Literal(p.latest_version)))

        repo = try_url_iri(p.repo)
        isnothing(repo) || push!(g, Triple(iri, sdo.codeRepository, repo))

        isnothing(p.subdir)    || push!(g, Triple(iri, jl.subdirectory, Literal(p.subdir)))
        isnothing(p.min_julia) || push!(g, Triple(iri, jl.minJuliaVersion, Literal(p.min_julia)))
        endswith(p.name, "_jll") && push!(g, Triple(iri, jl.isJLL, Literal(true)))
        p.name in STDLIBS && push!(g, Triple(iri, jl.isStdlib, Literal(true)))

        # Owner edge from the URL alone; the GraphQL phase adds the node's
        # type (Person vs Organization) and any richer metadata.
        isnothing(p.owner) || push!(g, Triple(iri, jl.owner, gh_actor_iri(p.owner)))

        for dep in p.dep_names
            dep in byname && push!(g, Triple(iri, jl.dependsOn, pkg_iri(dep)))
        end
    end

    g
end
