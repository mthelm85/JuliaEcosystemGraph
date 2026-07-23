# Ecosystem insights notebook

A [Quarto](https://quarto.org) notebook that renders a self-contained,
interactive data portrait of the Julia package ecosystem from
`../julia_ecosystem.nq`.

## Render

```powershell
quarto render ecosystem_insights.qmd
```

Produces `ecosystem_insights.html` — one **fully self-contained, offline**
file (~8.4 MB). Open it in any browser; no server or internet needed.

Requirements:
- Quarto, and the `julia-pkgkg-1.12` Jupyter kernel (an IJulia kernel bound to
  this folder's `Project.toml`). Recreate it if missing:
  ```powershell
  julia --project=. -e 'using IJulia; installkernel("Julia PkgKG", "--project=@.")'
  ```
- The built graph at `../julia_ecosystem.nq`.

## How it's wired (for future edits)

- **Julia cells** compute every insight (`graphtools.jl` holds the query and
  network helpers) and hand data to the browser with `embed_json(name, data)`,
  which writes `name.js` (`window.__DATA_name = …`) and a `<script src>` tag
  that Quarto's `embed-resources` inlines. This deliberately avoids two traps:
  `ojs_define` does **not** work under the Jupyter Julia engine, and large
  payloads printed to a cell's stdout are silently dropped by Jupyter's iopub
  rate limit.
- **Interactive figures** (scatter, force-directed network, package explorer)
  are plain JavaScript using a **vendored** copy of D3 in `libs/d3.min.js` —
  no Observable JS and no CDN, so the page works offline and under strict CSP.
- The `*.js` files in this folder are regenerated on every render; they are
  intermediate build artifacts, safe to delete.

Every figure carries its data source and caveats inline; see the notebook's
"Methods & limitations" section.
