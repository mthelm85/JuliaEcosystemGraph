# ── Checkpoint state ──────────────────────────────────────────────────────────
#
# Resumability is a JSON state file (out/state.json) plus one N-Triples file
# per phase.  The state file records which repos/logins each phase has already
# fetched and which phases are complete; the .nt files hold the triples
# produced so far.  Both are written together at checkpoints so they can never
# disagree by more than one checkpoint interval.

mutable struct BuildState
    path::String
    data::Dict{String,Any}
end

# JSON.parse may return its own dict/array types; normalize to plain
# Dict/Vector/String so the rest of the code never depends on JSON internals.
_plain(x::AbstractDict) = Dict{String,Any}(String(k) => _plain(v) for (k, v) in pairs(x))
_plain(x::AbstractVector) = Any[_plain(v) for v in x]
_plain(x::AbstractString) = String(x)
_plain(x) = x

function load_state(cfg::Config)::BuildState
    path = joinpath(cfg.out_dir, "state.json")
    if isfile(path)
        data = _plain(JSON.parse(read(path, String)))
        if get(data, "snapshot_date", "") == cfg.snapshot_date
            return BuildState(path, data)
        end
        @info "state.json is from $(get(data, "snapshot_date", "?")) — starting fresh snapshot $(cfg.snapshot_date)"
        # ONLY the *_snapshot.nt / downloads.nt files embed the snapshot date
        # in their node IRIs, so only those must be cleared on a date change.
        # The structural graphs (registry, github_static, contributors, users)
        # are date-independent and represent hours of crawling — never delete
        # them here. (A previous version wiped every .nt, which destroyed the
        # contributor crawl when an assemble-only run happened on a new day.)
        for f in readdir(cfg.out_dir)
            (endswith(f, "_snapshot.nt") || f == "downloads.nt") &&
                rm(joinpath(cfg.out_dir, f))
        end
    end
    BuildState(path, Dict{String,Any}("snapshot_date" => cfg.snapshot_date))
end

function save_state(st::BuildState)
    tmp = st.path * ".tmp"
    open(io -> write(io, JSON.json(st.data)), tmp, "w")
    mv(tmp, st.path; force=true)
end

done_set(st::BuildState, phase::String) =
    Set{String}(String.(get(st.data, phase * "_done", String[])))

function mark_done!(st::BuildState, phase::String, keys)
    arr = get!(() -> Any[], st.data, phase * "_done")
    append!(arr, keys)
    save_state(st)
end

phase_complete(st::BuildState, phase::String) =
    get(st.data, phase * "_complete", false) === true

function phase_complete!(st::BuildState, phase::String)
    st.data[phase * "_complete"] = true
    save_state(st)
end

# ── Per-phase graph persistence ───────────────────────────────────────────────

graph_path(cfg::Config, name::String) = joinpath(cfg.out_dir, name * ".nt")

function save_graph(cfg::Config, name::String, g::Graph)
    path = graph_path(cfg, name)
    tmp  = path * ".tmp"          # non-.ttl/.jsonld extension → N-Triples
    rdf_write(tmp, g)
    mv(tmp, path; force=true)
end

function load_graph(cfg::Config, name::String)::Graph
    path = graph_path(cfg, name)
    isfile(path) ? rdf_read(path) : Graph()
end
