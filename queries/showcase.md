# Showcase queries

Run any of these against the built graph:

```julia
using RDF
ds = rdf_read("julia_ecosystem.nq")
sparql(ds, QUERY)
```

Time-varying metrics live in dated snapshot named graphs, so those patterns
are wrapped in `GRAPH ?g { … }`; structural facts (names, dependencies,
contributors, topics) are in the default graph.

Common prologue (prepend to each query):

```sparql
PREFIX jl:      <https://julia-ecosystem.org/ns/>
PREFIX rdf:     <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs:    <http://www.w3.org/2000/01/rdf-schema#>
PREFIX dcterms: <http://purl.org/dc/terms/>
PREFIX foaf:    <http://xmlns.com/foaf/0.1/>
PREFIX sdo:     <https://schema.org/>
PREFIX xsd:     <http://www.w3.org/2001/XMLSchema#>
```

## Metric caveats

Rules any published analysis must respect (see the repo-level discussion in
each affected query):

- **Repo-level vs package-level.** Stars, forks, issues, commit counts, and
  contributor lists describe *repositories*. Packages in a monorepo share
  them. Aggregates must dedupe by `sdo:codeRepository` (see query 8).
- **Requests ≠ downloads ≠ users.** `jl:monthlyDownloads` is package-server
  request volume incl. CI (see query 11).
- **Commits ≠ contribution.** `jl:commits` counts commits; squash-merge
  cultures deflate it and review/triage work is invisible. Say "commit
  concentration", never "bus factor".
- **`jl:fundingLink` means a declared GitHub funding link.** Absence is not
  evidence a project is unfunded (NumFOCUS etc. may not use FUNDING.yml).
- **JLL wrappers** (`jl:isJLL true`) are auto-generated and dominate request
  counts; state whether each analysis includes or excludes them.
- **Contributor identity is a GitHub account**; bots are filtered by a
  published list plus the `[bot]` suffix, and the filter is best-effort.

---

## 1. The load-bearing packages

Top packages by number of direct dependents.

```sparql
SELECT ?name ?dependents WHERE {
  GRAPH ?g { ?s jl:forPackage ?pkg ; jl:directDependents ?dependents . }
  ?pkg rdfs:label ?name .
} ORDER BY DESC(?dependents) LIMIT 20
```

## 2. Underrated infrastructure

High dependency-PageRank but fewer than 100 stars — packages everyone uses
and nobody stars.

```sparql
SELECT ?name ?pr ?stars WHERE {
  GRAPH ?g { ?s jl:forPackage ?pkg ; jl:pagerank ?pr ; jl:stars ?stars . }
  ?pkg rdfs:label ?name .
  FILTER(?stars < 100)
} ORDER BY DESC(?pr) LIMIT 20
```

## 3. Abandoned but depended on

No push in two years (or archived), yet ten or more packages depend on it —
the ecosystem's bus-factor risk list.

```sparql
SELECT ?name ?dependents ?pushed WHERE {
  GRAPH ?g {
    ?s jl:forPackage ?pkg ;
       jl:directDependents ?dependents ;
       jl:lastPushedAt ?pushed .
  }
  ?pkg rdfs:label ?name .
  FILTER(?dependents >= 10 && ?pushed < "2024-07-20T00:00:00"^^xsd:dateTime)
} ORDER BY DESC(?dependents)
```

## 4. The connectors

People contributing to the most packages.

```sparql
SELECT ?login (COUNT(DISTINCT ?pkg) AS ?npkgs) WHERE {
  ?pkg dcterms:contributor ?person .
  ?person foaf:nick ?login .
} GROUP BY ?login ORDER BY DESC(?npkgs) LIMIT 25
```

## 5. Top committers to one package (RDF-star)

Contribution weights are RDF 1.2 reification annotations on the
`dcterms:contributor` statements.

```sparql
SELECT ?login ?n WHERE {
  ?r rdf:reifies <<( <https://juliahub.com/ui/Packages/General/DataFrames>
                     dcterms:contributor ?person )>> .
  ?r jl:commits ?n .
  ?person foaf:nick ?login .
} ORDER BY DESC(?n) LIMIT 15
```

## 6. Heaviest dependency footprints

Transitive dependency closure size per package (property path).

```sparql
SELECT ?name (COUNT(DISTINCT ?dep) AS ?closure) WHERE {
  ?pkg jl:dependsOn+ ?dep .
  ?pkg rdfs:label ?name .
} GROUP BY ?name ORDER BY DESC(?closure) LIMIT 20
```

## 7. Who do you trust when you `] add` something?

Every person who has ever committed to anything in a package's transitive
dependency tree.

```sparql
SELECT (COUNT(DISTINCT ?person) AS ?people) WHERE {
  <https://juliahub.com/ui/Packages/General/Makie> jl:dependsOn* ?dep .
  ?dep dcterms:contributor ?person .
}
```

## 8. Organization league table

Stars aggregated per owning GitHub account. **Stars are a repository-level
metric**: every package in a monorepo carries its repo's star count, so the
inner subquery collapses to one row per repository before summing —
otherwise a monorepo's stars would be counted once per subpackage.

```sparql
SELECT ?owner (SUM(?repoStars) AS ?totalStars) (COUNT(?repo) AS ?repos) WHERE {
  {
    SELECT ?owner ?repo (MAX(?stars) AS ?repoStars) WHERE {
      ?pkg jl:owner ?owner ; sdo:codeRepository ?repo .
      GRAPH ?g { ?s jl:forPackage ?pkg ; jl:stars ?stars . }
    } GROUP BY ?owner ?repo
  }
} GROUP BY ?owner ORDER BY DESC(?totalStars) LIMIT 20
```

## 9. Topic neighborhoods

What co-occurs with #machine-learning?

```sparql
SELECT ?other (COUNT(?pkg) AS ?n) WHERE {
  ?pkg dcterms:subject <https://github.com/topics/machine-learning> ;
       dcterms:subject ?other .
  FILTER(?other != <https://github.com/topics/machine-learning>)
} GROUP BY ?other ORDER BY DESC(?n) LIMIT 15
```

## 10. Corporate footprint

Where do the ecosystem's cross-package contributors work?  (Employers are
self-reported GitHub profile fields on people contributing to 3+ packages.)

```sparql
SELECT ?company (COUNT(DISTINCT ?person) AS ?people) WHERE {
  ?person sdo:worksFor ?company .
} GROUP BY ?company ORDER BY DESC(?people) LIMIT 20
```

## 11. Quiet workhorses

Heavily requested, barely starred. **Caveat:** `jl:monthlyDownloads` counts
package-server *requests* (juliapkgstats.com), which include CI traffic —
treat it as an install-demand signal, not a count of humans.

```sparql
SELECT ?name ?dl ?stars WHERE {
  GRAPH ?g {
    ?s jl:forPackage ?pkg ;
       jl:monthlyDownloads ?dl ;
       jl:stars ?stars .
  }
  ?pkg rdfs:label ?name .
  FILTER(?stars < 50 && ?dl > 100000)
} ORDER BY DESC(?dl) LIMIT 20
```

## 12. Unfunded and load-bearing

High direct-dependent counts with no declared funding link — a sponsorship
shortlist.

```sparql
SELECT ?name ?dependents WHERE {
  GRAPH ?g { ?s jl:forPackage ?pkg ; jl:directDependents ?dependents . }
  ?pkg rdfs:label ?name .
  OPTIONAL { ?pkg jl:fundingLink ?f }
  FILTER(!BOUND(?f) && ?dependents >= 20)
} ORDER BY DESC(?dependents) LIMIT 25
```

## 13. Time series (needs two or more snapshot dates)

Star growth for one package across builds.

```sparql
SELECT ?date ?stars WHERE {
  GRAPH ?g {
    ?s jl:forPackage <https://juliahub.com/ui/Packages/General/DataFrames> ;
       jl:observedAt ?date ;
       jl:stars ?stars .
  }
} ORDER BY ?date
```

## 14. Beyond SPARQL: Graphs.jl analysis

The dependency network converts straight into Graphs.jl for anything SPARQL
can't express:

```julia
using RDF, Graphs
ds  = rdf_read("julia_ecosystem.nq")
jl  = Namespace("https://julia-ecosystem.org/ns/")
res = to_digraph(ds.default_graph, jl.dependsOn)
core = k_core(res.graph, 5)                      # the tightly-coupled core
names = [resolve_term(res.terms[v]) for v in core]
```
