# ── Phase 5: Download statistics (juliapkgstats.com) ──────────────────────────
#
# No auth and no meaningful rate limit, so this runs concurrently and
# finishes in minutes.  Not resumed item-by-item — an interrupted run just
# redoes the phase.

function fetch_downloads!(cfg::Config, st::BuildState, pkgs::Vector{PkgInfo})
    gsnap  = Graph()
    total  = length(pkgs)
    done   = Ref(0)
    added  = Ref(0)
    g_lock = ReentrantLock()
    sem    = Base.Semaphore(cfg.dl_concurrent)

    tasks = map(pkgs) do p
        Threads.@spawn begin
            Base.acquire(sem)
            count = try
                buf  = IOBuffer()
                resp = Downloads.request(
                    "https://juliapkgstats.com/api/v2/monthly_downloads/$(p.name)";
                    output=buf, timeout=10.0)
                if resp.status == 200
                    d = JSON.parse(String(take!(buf)))
                    v = d isa AbstractDict ? get(d, "total_requests", nothing) : nothing
                    isnothing(v) ? nothing : Int64(v)
                else
                    nothing
                end
            catch
                nothing
            finally
                Base.release(sem)
            end

            lock(g_lock) do
                done[] += 1
                if !isnothing(count)
                    snap = snapshot_core!(gsnap, cfg, p.name)
                    push!(gsnap, Triple(snap, jl.monthlyDownloads, Literal(count)))
                    added[] += 1
                end
                (done[] % 1000 == 0 || done[] == total) &&
                    @printf("  downloads: %d / %d\n", done[], total)
            end
        end
    end

    foreach(wait, tasks)
    save_graph(cfg, "downloads", gsnap)
    println("  download stats for $(added[]) packages")
end
