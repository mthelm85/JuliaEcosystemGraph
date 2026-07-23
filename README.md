# JuliaEcosystemGraph

A knowledge graph of the entire Julia package ecosystem — every registered
package, its dependency network, GitHub metadata, and the people who build it —
assembled into a single queryable [RDF](https://www.w3.org/RDF/) dataset and
explored three ways: a reproducible pipeline, an analytical report, and a
browser-based SPARQL explorer that runs with no backend.

Built on [RDF.jl](https://github.com/mthelm85/RDF.jl).

## Explore it

| | |
|---|---|
| **Live SPARQL explorer** | Query the whole graph in your browser — [mthelm85.github.io/JuliaEcosystemGraph](https://mthelm85.github.io/JuliaEcosystemGraph/) |
| **Analytical report** | [`notebook/`](notebook/) — an interactive Quarto notebook of ecosystem findings |
| **The dataset** | `julia_ecosystem.nq` — one N-Quads file, ~864k triples over ~14k packages |
| **Example queries** | [`queries/showcase.md`](queries/showcase.md) — a tour of what the graph can answer |

## What's in the graph

| Source | Contributes | Cost |
|---|---|---|
| General registry (local) | identity, UUIDs, versions, dependency edges, compat, monorepo subdirs, stdlib/JLL flags | seconds |
| GitHub GraphQL | description, topics, license, owner, stars/forks/issues/PRs, commit & release counts, funding links, fork lineage | ~20 min |
| GitHub REST `/contributors` | per-package contributor logins + commit counts | ~3.5 h (rate-limited) |
| GitHub REST `/users` | profiles (name, employer, location) for people on 3+ packages | ~1 h |
| juliapkgstats.com | monthly package-server request counts | ~10 min |
| derived (local) | dependency PageRank, direct- and transitive-dependent counts | seconds |

## Graph design

**Entity IRIs are real URLs.** Every node dereferences to an actual web page,
so results are clickable and the data joins to anything else keyed the same way:

| Entity | IRI scheme | Class |
|---|---|---|
| Package | `https://juliahub.com/ui/Packages/General/{Name}` | `jl:Package` ⊂ `schema:SoftwareSourceCode` |
| Person / Org | `https://github.com/{login}` | `foaf:Person` / `foaf:Organization` |
| Topic | `https://github.com/topics/{topic}` | `skos:Concept` |
| License | `https://spdx.org/licenses/{SPDX-ID}` | `dcterms:LicenseDocument` |
| Snapshot | `https://julia-ecosystem.org/snapshots/{date}[/{Name}]` | `jl:Snapshot` / `jl:PackageSnapshot` |

**Two layers.** Stable facts (names, dependencies, contributors, topics,
licenses) live in the default graph; time-varying metrics (stars, downloads,
PageRank, …) live in a per-date named graph, so re-running the pipeline
accumulates a queryable time series in the same file.

**Contribution weights are RDF-star.** Each `pkg dcterms:contributor person`
statement carries a `jl:commits n` annotation via RDF 1.2 reification, so *who*
contributed and *how much* are both queryable.

**Self-describing.** Custom `jl:` terms are declared in the graph with labels,
comments, and domains/ranges, and the whole dataset is validated against
[SHACL shapes](src/shapes.jl) at assembly time.

## Project layout

```
src/            the pipeline — one file per phase (registry, github, contributors,
                users, downloads, derived, assemble) + ontology, SHACL shapes, state
scripts/build.jl  orchestrator entry point (resumable, phase-selectable)
queries/        showcase SPARQL queries
notebook/       Quarto analytical report (ecosystem_insights.qmd) + its compute layer
web/            client-side SPARQL explorer (vendored Oxigraph WASM, no backend)
.github/        GitHub Pages deployment for the explorer
```

## Building the dataset

```powershell
$env:GITHUB_TOKEN = "ghp_..."          # public-repo read scope is enough
julia --project -t auto scripts/build.jl
```

The full build is **~5 hours**, dominated by the rate-limited contributor
crawl. It is **safe to interrupt**: progress is checkpointed to `out/` every
200 items and the next run resumes where it stopped; completed phases are
skipped. Run individual phases with e.g. `scripts/build.jl registry assemble`;
smoke-test the whole pipeline in minutes with `$env:PKG_LIMIT = "40"`.

Assembly validates the dataset with RDF validation plus SHACL shapes before
writing `julia_ecosystem.nq`.

## Querying it directly

```julia
using RDF
ds = rdf_read("julia_ecosystem.nq")
sparql(ds, """
    PREFIX jl:   <https://julia-ecosystem.org/ns/>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    SELECT ?name ?transitive WHERE {
      GRAPH ?g { ?s jl:forPackage ?pkg ; jl:transitiveDependents ?transitive . }
      ?pkg rdfs:label ?name .
      FILTER NOT EXISTS { ?pkg jl:isJLL true }
      FILTER NOT EXISTS { ?pkg jl:isStdlib true }
    } ORDER BY DESC(?transitive) LIMIT 20""")
```

[`queries/showcase.md`](queries/showcase.md) has the full tour: load-bearing
packages, underrated infrastructure, cross-package contributors, corporate
footprint, topic neighborhoods, funding gaps, the dependency-tree trust
surface, and Graphs.jl network analysis via `to_digraph`.

## Notes

- **The report** ([`notebook/README.md`](notebook/README.md)) renders to one
  self-contained, offline HTML file — vendored D3, data inlined, no CDN.
- **The explorer** ([`web/README.md`](web/README.md)) loads the whole graph
  (~7 MB gzipped) into an in-browser Oxigraph store in ~4 s, then answers
  SPARQL — including property paths and RDF-star — in tens of milliseconds,
  entirely client-side.
- `julia_ecosystem.nq`, `out/`, and render artifacts are git-ignored; the
  published snapshot the explorer serves is committed as `web/data.nq.gz`.
