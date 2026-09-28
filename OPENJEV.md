# OpenJEV Support

This fork adds optional [OpenJEV](https://openjev.sh) support alongside TypeSafe.
TypeSafe remains the default; OpenJEV is a free community gateway to the same Jev model.

## What was added

| File | Change |
| --- | --- |
| `lib/typesafe/client.ex` | Provider selection logic (`apply_provider/2`, `resolve_provider/1`): resolves `JEV_PROVIDER`/`:provider` and `OPENJEV_API_KEY`/`:openjev_api_key`; when OpenJEV is selected, api\_key comes from `OPENJEV_API_KEY`, `base_url` defaults to `https://api.openjev.sh`, `model` defaults to `"openjev"`. Updated `@env_vars` and `resolve/1`. Updated missing-key error message. |
| `lib/typesafe/req.ex` | `attach/2` accepts `:provider` and `:openjev_api_key` options, passes them to `Client.new/1`. |
| `README.md` | OpenJEV note after the intro and an OpenJEV configuration subsection. |

No TypeSafe defaults, imports, or behaviour were changed. The retry policy already
covers HTTP 503 (OpenJEV's overload status) via the `500..599` range.

## Provider selection rule

1. **Explicit choice wins**: `JEV_PROVIDER=openjev` (env) or `provider: :openjev` (option).
2. **Otherwise**, if `TYPESAFE_API_KEY` is set → TypeSafe (unchanged default).
3. **Otherwise**, if only `OPENJEV_API_KEY` is set → OpenJEV.

When OpenJEV is selected:
- API key: `OPENJEV_API_KEY` env (or `:openjev_api_key` option), unless an explicit `:api_key`
  was passed to `TypeSafe.new/1`.
- `base_url`: `https://api.openjev.sh` (unless overridden by `:base_url`, `TYPESAFE_BASE_URL`,
  or `config :typesafe, :base_url`).
- `model`: `"openjev"` (unless overridden by `:model`, `TYPESAFE_DEFAULT_MODEL`,
  or `config :typesafe, :model`).

Anyone with a `TYPESAFE_API_KEY` sees zero behaviour change.

## Configuration

```bash
# Explicit provider
export JEV_PROVIDER=openjev
export OPENJEV_API_KEY=oj_...

# Or auto-detected (no TYPESAFE_API_KEY set)
export OPENJEV_API_KEY=oj_...
```

```elixir
# Explicit option
client = TypeSafe.new(provider: :openjev, openjev_api_key: "oj_...")

# Or via the Req plugin
Req.new() |> TypeSafe.Req.attach(provider: :openjev, openjev_api_key: "oj_...")
```

## Verification

- A live `POST https://api.openjev.sh/v1/systemone` request with model `openjev`,
  state `"ping"`, and one noul question returned HTTP 200.
- `grep -r "api.typesafe.ai" lib/` confirms no hardcoded TypeSafe default was changed;
  `api.typesafe.ai` remains the TypeSafe provider default and appears only in
  TypeSafe-specific docs, examples, and error messages.

## Upstream

Original project: https://github.com/mattneel/typesafe by @mattneel.
