# Web site (report + explorer)

The published GitHub Pages site: the analytical report as the landing page,
linking to a fully client-side SPARQL explorer for `julia_ecosystem.nq`. The
explorer runs in the browser via [Oxigraph](https://github.com/oxigraph/oxigraph)
compiled to WebAssembly — no server, no backend, no data leaves the page.

## Contents

| File | What it is |
|------|------------|
| `index.html` | The report (rendered from [`../notebook/ecosystem_insights.qmd`](../notebook)) — the landing page |
| `explorer.html` | The SPARQL query UI (example queries, editor, results table) |
| `web.js`, `web_bg.wasm` | Vendored Oxigraph WASM build (v0.5.9) — no CDN |
| `data.nq.gz` | The dataset, gzipped (~7 MB; ~140 MB / 864k triples uncompressed) |

`index.html` is a copy of the rendered notebook; after re-rendering the report,
refresh it with `cp notebook/ecosystem_insights.html web/index.html`.

## How it works

On load the page fetches `data.nq.gz`, gunzips it with the native
`DecompressionStream`, and bulk-loads it into an in-memory Oxigraph store
(`no_transaction` + `unchecked`, safe because the file is pre-validated).
First load is a one-time ~4 s parse (~140 MB heap); queries then run in
tens of milliseconds.

## Deployment

Pushed to GitHub Pages by [`.github/workflows/pages.yml`](../.github/workflows/pages.yml),
which uploads this folder as the site. Enable Pages with **Settings → Pages →
Source: GitHub Actions**.

## Refreshing the data

After rebuilding the graph, regenerate the served snapshot:

```bash
gzip -c -9 julia_ecosystem.nq > web/data.nq.gz
```

Commit the new `web/data.nq.gz`; the workflow redeploys on push.

## Updating Oxigraph

```bash
curl -Lo web/web.js       https://cdn.jsdelivr.net/npm/oxigraph@<ver>/web.js
curl -Lo web/web_bg.wasm  https://cdn.jsdelivr.net/npm/oxigraph@<ver>/web_bg.wasm
```
