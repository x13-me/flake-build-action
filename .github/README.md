# Secrets required on this repo

```elixir
EXTRA_SUBSTITUTER     — substituter URL, https//user:pass@host/ format
EXTRA_SUBSTITUTER_KEY — public key for the extra substituter
PRIVATE_REPO_PAT      — PAT with `contents: read` on any private repo that dispatches here
```

## Optional lockfile update
Opt-in full `nix flake update` before building; build-only, never committed or pushed.
workflow_dispatch: `update_flake: true` (default `false`); repository_dispatch: `update_flake` in `client_payload` is a JSON boolean (`true`/`false`), missing means `false`.
```json
{"repo": "owner/private-repo", "ref": "main", "update_flake": true}
```
