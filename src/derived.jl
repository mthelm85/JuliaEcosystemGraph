# ── Phase 6: Derived network metrics ──────────────────────────────────────────
#
# Runs at assembly time on the finished jl:dependsOn graph — no network, no
# resume needed.  PageRank over dependency edges surfaces load-bearing
# packages (mass flows from dependents to dependencies); in-degree counts
# direct dependents; reachability counts transitive dependents ("blast
# radius" — the graph-native measure of how much would break).

# Edge a→b means "a depends on b", so the packages that transitively depend on
# b are exactly those that can reach b.  Count them for every vertex via SCC
# condensation + reverse-topo BitSet union — cycle-safe and O(V+E) in sets.
function transitive_dependent_counts(dg)
    N   = Graphs.nv(dg)
    rev = Graphs.reverse(dg)                    # b→a : "a depends on b"
    sccs = Graphs.strongly_connected_components(rev)
    comp = Vector{Int}(undef, N)
    for (ci, c) in enumerate(sccs), v in c
        comp[v] = ci
    end
    C    = length(sccs)
    cond = Graphs.SimpleDiGraph(C)
    for e in Graphs.edges(rev)
        cu, cv = comp[Graphs.src(e)], comp[Graphs.dst(e)]
        cu == cv || Graphs.add_edge!(cond, cu, cv)
    end
    memb = [BitSet() for _ in 1:C]
    for v in 1:N
        push!(memb[comp[v]], v)
    end
    clo = [BitSet() for _ in 1:C]
    for c in reverse(Graphs.topological_sort_by_dfs(cond))
        acc = copy(memb[c])
        for w in Graphs.outneighbors(cond, c)
            union!(acc, clo[w])
        end
        clo[c] = acc
    end
    [length(clo[comp[v]]) - 1 for v in 1:N]      # minus self
end

function add_derived!(gsnap::Graph, gdefault::Graph, cfg::Config)
    res = to_digraph(gdefault, jl.dependsOn)
    n   = Graphs.nv(res.graph)
    n == 0 && return

    pr   = Graphs.pagerank(res.graph)
    tdep = transitive_dependent_counts(res.graph)
    for v in 1:n
        term = resolve_term(res.terms[v])
        term isa IRI || continue
        startswith(term.value, PKG_BASE) || continue
        name = String(chopprefix(term.value, PKG_BASE))

        snap = snapshot_core!(gsnap, cfg, name)
        push!(gsnap, Triple(snap, jl.pagerank, Literal(round(pr[v]; sigdigits=6))))
        push!(gsnap, Triple(snap, jl.directDependents,
                            Literal(Graphs.indegree(res.graph, v))))
        push!(gsnap, Triple(snap, jl.transitiveDependents, Literal(tdep[v])))
    end
    println("  derived metrics for $n packages in the dependency graph")
end
