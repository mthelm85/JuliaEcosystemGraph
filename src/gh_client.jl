# ── GitHub API client ─────────────────────────────────────────────────────────
#
# One client for both APIs, with the rate-limit discipline in a single place:
#
#   REST    — sequential, paced to ~1.3 req/s (≈4 700/hr, under the 5 000/hr
#             cap), and the x-ratelimit-remaining/x-ratelimit-reset response
#             headers are honored: when remaining runs low we sleep until the
#             window resets.  GitHub's secondary limits punish REST
#             concurrency, so everything REST is single-threaded.
#   GraphQL — every query carries a rateLimit { cost remaining resetAt } block
#             and we sleep until resetAt when the point budget runs low.

mutable struct GHClient
    token::String
    last_request::Float64
    min_interval::Float64
end

GHClient(token::String) = GHClient(token, 0.0, 0.75)

function _throttle!(c::GHClient)
    dt = time() - c.last_request
    dt < c.min_interval && sleep(c.min_interval - dt)
    c.last_request = time()
end

_headers(c::GHClient) = [
    "Authorization"        => "Bearer $(c.token)",
    "Accept"               => "application/vnd.github+json",
    "X-GitHub-Api-Version" => "2022-11-28",
    "User-Agent"           => "JuliaEcosystemGraph.jl",
]

function _header(resp, name::String)::Union{String,Nothing}
    for (k, v) in resp.headers
        lowercase(k) == name && return v
    end
    nothing
end

# Sleep out the primary rate-limit window when the header says we're low.
function _respect_rest_limit(resp)
    rem = _header(resp, "x-ratelimit-remaining")
    rst = _header(resp, "x-ratelimit-reset")
    (isnothing(rem) || isnothing(rst)) && return
    remaining = something(tryparse(Int, rem), typemax(Int))
    remaining > 50 && return
    reset_at = something(tryparse(Float64, rst), 0.0)
    wait_s = clamp(reset_at - time() + 5.0, 0.0, 3700.0)
    wait_s > 0 || return
    @info "REST rate limit nearly exhausted — sleeping $(round(Int, wait_s))s until reset"
    sleep(wait_s)
end

"""
    rest_get(client, path) -> parsed JSON | nothing

GET an api.github.com path.  Returns the parsed JSON body on 200, `nothing`
for permanently missing resources (404/410/451) or after exhausting retries.
"""
function rest_get(c::GHClient, path::String; retries::Int=4)
    url = "https://api.github.com" * path
    for attempt in 1:retries
        _throttle!(c)
        buf  = IOBuffer()
        resp = try
            Downloads.request(url; method="GET", output=buf,
                              headers=_headers(c), timeout=30.0)
        catch e
            @warn "network error (attempt $attempt)" url exception=(e,)
            sleep(10.0 * attempt)
            continue
        end

        _respect_rest_limit(resp)

        if resp.status == 200
            return JSON.parse(String(take!(buf)))
        elseif resp.status in (404, 410, 451, 204)
            return nothing
        elseif resp.status in (403, 429)
            ra     = _header(resp, "retry-after")
            wait_s = isnothing(ra) ? 60.0 * attempt : something(tryparse(Float64, ra), 60.0)
            @warn "HTTP $(resp.status) — backing off $(wait_s)s (attempt $attempt)" url
            sleep(wait_s)
        elseif resp.status >= 500
            sleep(15.0 * attempt)
        else
            @warn "HTTP $(resp.status)" url
            return nothing
        end
    end
    @warn "giving up after $retries attempts" url
    nothing
end

# ── GraphQL ───────────────────────────────────────────────────────────────────

function _respect_graphql_limit(rl)
    remaining = get(rl, "remaining", nothing)
    isnothing(remaining) && return
    Int(remaining) > 100 && return
    reset_dt = gh_datetime(get(rl, "resetAt", ""))
    wait_s = isnothing(reset_dt) ? 900.0 :
             clamp(datetime2unix(reset_dt) - time() + 5.0, 0.0, 3700.0)
    @info "GraphQL point budget nearly exhausted — sleeping $(round(Int, wait_s))s"
    sleep(wait_s)
end

"""
    graphql(client, query) -> data | nothing

POST a GraphQL query.  The query should include a top-level
`rateLimit { cost remaining resetAt }` field; the client uses it to pace
itself.  NOT_FOUND errors (deleted/renamed repos) are expected and ignored.
"""
function graphql(c::GHClient, query::String; retries::Int=4)
    body = JSON.json(Dict("query" => query))
    headers = ["Authorization" => "Bearer $(c.token)",
               "Content-Type"  => "application/json",
               "User-Agent"    => "JuliaEcosystemGraph.jl"]
    for attempt in 1:retries
        _throttle!(c)
        buf  = IOBuffer()
        resp = try
            Downloads.request("https://api.github.com/graphql";
                              method="POST", input=IOBuffer(body), output=buf,
                              headers=headers, timeout=90.0)
        catch e
            @warn "GraphQL network error (attempt $attempt)" exception=(e,)
            sleep(15.0 * attempt)
            continue
        end

        if resp.status == 200
            parsed = JSON.parse(String(take!(buf)))
            errs   = get(parsed, "errors", nothing)
            if !isnothing(errs)
                real = [e for e in errs if get(e, "type", "") != "NOT_FOUND"]
                isempty(real) || @warn "GraphQL errors" errors=real
            end
            data = get(parsed, "data", nothing)
            if !isnothing(data)
                rl = get(data, "rateLimit", nothing)
                isnothing(rl) || _respect_graphql_limit(rl)
                return data
            end
            sleep(5.0 * attempt)
        elseif resp.status in (403, 429)
            ra     = _header(resp, "retry-after")
            wait_s = isnothing(ra) ? 60.0 * attempt : something(tryparse(Float64, ra), 60.0)
            @warn "GraphQL HTTP $(resp.status) — backing off $(wait_s)s (attempt $attempt)"
            sleep(wait_s)
        else
            @warn "GraphQL HTTP $(resp.status) (attempt $attempt)"
            attempt < retries && sleep(10.0)
        end
    end
    nothing
end

function check_token(c::GHClient)
    data = graphql(c, "{ viewer { login } rateLimit { cost remaining resetAt } }"; retries=2)
    isnothing(data) &&
        error("GitHub token check failed — verify GITHUB_TOKEN is valid and not expired")
    println("  authenticated as: $(data["viewer"]["login"])")
end
