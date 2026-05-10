# Env File Management

## Rules

1. Every tunable env var must appear in `deploy/env/remnanode.env.example` with a comment.
2. Default values live in two places — top-of-script `VAR="${VAR:-N}"` and the heredoc env template. Keep them in sync.
3. Upgrade scripts read existing env via `source` then write back with `update_key_value_file` — don't overwrite the whole file.

## Known Tuning Vars

| Var | Default | Notes |
|-----|---------|-------|
| `XRAY_START_TIMEOUT` | 50 | Seconds for xray gRPC API to bind. Increase on weak LXC CPUs with REALITY inbound. |
| `XTLS_API_PORT` | 61000 | Internal xray stats/control port. |
| `UV_THREADPOOL_SIZE` | 1 | Reduce on low-memory hosts. |
| `MALLOC_ARENA_MAX` | 1 | Reduce memory fragmentation. |
