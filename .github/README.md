# Secrets required on this repo

```elixir
TARGET           - push cache, `user:pass@hostname` (build outputs pushed to
                   `https://$TARGET/upload?compression=zstd`)
CACHE            - pull substituter, `user:pass@hostname`
                   (`https://$CACHE/?priority=100`)
CACHE_KEY        - trusted public key for the pull cache
PRIVATE_REPO_PAT - PAT with `contents: read` on repos being built; add
                   commit-status write for repos that receive status writeback
```

## Optional lockfile update
Opt-in full `nix flake update` before building; build-only, never committed or pushed.
workflow_dispatch: `update_flake: true` (default `false`); repository_dispatch: `update_flake` in `client_payload` is a JSON boolean (`true`/`false`), missing means `false`.
```json
{"repo": "owner/private-repo", "ref": "main", "update_flake": true}
```

## Status writeback gate
Commit-status writeback is off by default (`report_status: false`), so repos that cannot receive statuses (and existing dispatchers that do not send the flag) are unaffected. Set `report_status: true` to enable it for a repo the PAT can write to. `workflow_dispatch` exposes it as the `report_status` input; `repository_dispatch` accepts `report_status` in `client_payload` (missing/null defaults to `false`). When disabled, the workflow skips all status posts and the `report` job.

## Run reporting (async, no polling, no private compute)
`repository_dispatch` returns no run reference. This workflow reports back to the
source commit (the checked-out private ref's HEAD SHA) by posting commit statuses
with `target_url` set to the public workflow run, using `PRIVATE_REPO_PAT`. The dispatch
workflow finishes after sending the event.

Two contexts are reported separately:
- `nix-build/generate-matrix`: `pending` while enumerating targets, then
  `success`/`failure`/`error` when matrix generation ends.
- `nix-build/result`: set to `pending` ("Builds in progress") when builds start, then
  `success`/`failure`/`error` after all matrix build jobs complete. Resolved immediately
  on matrix failure or when there are no buildable targets.

Optional correlation field accepted in `client_payload` (see `sample/dispatch.yml`):
`dispatch_id` (opaque; avoid values that contain the source repo identifier).
