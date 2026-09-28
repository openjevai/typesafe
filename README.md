# TypeSafe

[![Hex.pm](https://img.shields.io/hexpm/v/typesafe.svg)](https://hex.pm/packages/typesafe)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/typesafe)

Elixir client for TypeSafe's [System One API](https://docs.typesafe.ai/concepts/system-one.md)
and its Jev model. Ask typed Choice, Noul and Score questions about your application's state in
one request, and get back structs with probabilities that your code acts on.

This is a community client, not an official TypeSafe SDK.

> **OpenJEV support:** Jev is built by [TypeSafe](https://typesafe.ai). This fork keeps TypeSafe as the default and adds optional support for [OpenJEV](https://openjev.sh), a free community gateway to the same Jev model — set `OPENJEV_API_KEY` (or `JEV_PROVIDER=openjev`) to use it. Original project: https://github.com/mattneel/typesafe by @mattneel.

```elixir
client = TypeSafe.new(api_key: System.fetch_env!("TYPESAFE_API_KEY"))

questions = %{
  is_urgent:
    TypeSafe.noul("Does this convey urgency?",
      criteria: %{true: "Explicitly time-sensitive", false: "No urgency expressed"}
    ),
  department:
    TypeSafe.choice("Which team should handle this?",
      billing: "Payments, invoicing, refunds",
      technical: "Bugs, outages, integrations",
      sales: nil
    ),
  frustration: TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
}

{:ok, %TypeSafe.Response{answers: answers}} =
  TypeSafe.ask(client, "Help! My payouts have been failing for 3 days.", questions)

answers.is_urgent.noul            #=> 0.95
answers.department.choice         #=> :billing
answers.department.probabilities  #=> %{billing: 0.87, technical: 0.13, sales: 0.0}
answers.department.confidence     #=> 0.81
answers.frustration.score         #=> 1.05
```

The SDK returns judgments as data. Thresholds and policy stay in your code.

## Installation

Add `typesafe` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:typesafe, "~> 0.1.0"}
  ]
end
```

Requirements: Elixir 1.18 or later (for the standard library `JSON` module) and Erlang/OTP 27
or later. Runtime dependencies are [Req](https://hex.pm/packages/req) (`~> 0.7.4 or ~> 0.8`),
[Zoi](https://hex.pm/packages/zoi) and [Telemetry](https://hex.pm/packages/telemetry). The
`TypeSafe.Test` helpers also need [Plug](https://hex.pm/packages/plug), which you already have
if you use `Req.Test`.

Get an API key from the [TypeSafe quick start](https://docs.typesafe.ai/introduction/quickstart.md)
and export it as `TYPESAFE_API_KEY`.

## What you get back

`TypeSafe.ask/4` returns `{:ok, %TypeSafe.Response{}}` or `{:error, %TypeSafe.Error{}}`:

```elixir
%TypeSafe.Response{
  model: "jev-1.13.0",
  request_id: "req_01a0ac97618c76898e35b41bf6d9aa5e",
  raw: %{...},
  answers: %{
    is_urgent: %TypeSafe.Answer.Noul{noul: 0.95},
    department: %TypeSafe.Answer.Choice{
      choice: :billing,
      confidence: 0.81,
      probabilities: %{billing: 0.87, technical: 0.13, sales: 0.0}
    },
    frustration: %TypeSafe.Answer.Score{
      score: 1.05,
      confidence: 0.93,
      legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
      probabilities: %{0 => 0.0, 1 => 0.95, 2 => 0.05}
    }
  },
  usage: %TypeSafe.Usage{input_tokens: 414, output_tokens: 73}
}
```

- Answers come back under your question ids with your key type. Atom ids and atom Choice
  options stay atoms, and strings stay strings.
- `model` is the concrete version that answered, such as `"jev-1.13.0"`, even when you asked
  for the `"jev-latest"` alias.
- Score `legend` and `probabilities` are keyed by integer level, so you can write
  `probabilities[2]`.
- `raw` holds the decoded JSON body. An answer of a type this SDK version does not know is
  skipped with a warning and stays readable there.

| Answer | Fields | Helpers |
| --- | --- | --- |
| `TypeSafe.Answer.Noul` | `noul` | `yes?/2` |
| `TypeSafe.Answer.Choice` | `choice`, `probabilities`, `confidence` | `ranked/1`, `margin/1` |
| `TypeSafe.Answer.Score` | `score`, `legend`, `probabilities`, `confidence` | `expected_level/1`, `max_level/1`, `ranked/1` |

`TypeSafe.Response.fetch!/2` raises a `KeyError` that names the missing id, and
`TypeSafe.Response.nouls/1`, `choices/1` and `scores/1` filter answers by type.

## Configuration

A client is an immutable value with no process state. Build it with `TypeSafe.new/1` and share
it across processes. Each option resolves in this order: the option passed to `new/1`, then its
`TYPESAFE_*` environment variable (blank values are ignored), then `config :typesafe`, then the
default.

| Option | Env var | Default | Description |
| --- | --- | --- | --- |
| `:api_key` | `TYPESAFE_API_KEY` | required | Sent as `Authorization: Bearer <key>`. A missing key raises `ArgumentError` in `new/1`. |
| `:base_url` | `TYPESAFE_BASE_URL` | `"https://api.typesafe.ai"` | API base URL. |
| `:model` | `TYPESAFE_DEFAULT_MODEL` | `"jev-latest"` | Default model. `"jev-preview"` is also available. |
| `:timeout` | | `10_000` | Receive timeout in milliseconds for each HTTP operation. The connect timeout comes from the Finch pool. |
| `:retry` | | `%TypeSafe.Retry{}` | Retry policy, retry options as a keyword list, or `false`. |
| `:headers` | | `[]` | Extra request headers. Atom names use dashes (`:x_team` is sent as `x-team`). Auth and SDK identification headers cannot be overridden. |
| `:finch` | | Req's default pool | Req's `:finch` options, such as `[name: MyApp.Finch]`. |
| `:req_options` | | `[]` | Req options merged last. Values from config and from `new/1` are merged. `:retry_delay` is rejected while `:retry` is a policy; use `retry: [backoff_initial_ms: 0]`. |

```elixir
# config/runtime.exs
config :typesafe,
  api_key: System.get_env("TYPESAFE_API_KEY"),
  model: "jev-latest"
```

`ask/4` also takes per-call `:model`, `:timeout`, `:retry`, `:headers` and
`:telemetry_metadata` options. `TYPESAFE_LOG_LEVEL` is not read: configure Elixir's `Logger`
instead. See `TypeSafe.Client` for details.

### OpenJEV

[OpenJEV](https://openjev.sh) is a free community gateway to the same Jev model. TypeSafe
stays the default; OpenJEV is opt-in. Set `JEV_PROVIDER=openjev` (or pass `provider: :openjev`)
to select it explicitly, or simply set `OPENJEV_API_KEY` without a `TYPESAFE_API_KEY`:

```bash
# Option 1: explicit provider
export JEV_PROVIDER=openjev
export OPENJEV_API_KEY=...

# Option 2: auto-detected (no TYPESAFE_API_KEY set)
export OPENJEV_API_KEY=...
```

When OpenJEV is selected, the API key comes from `OPENJEV_API_KEY`, `base_url` defaults to
`https://api.openjev.sh` and `model` defaults to `"openjev"`. Explicit `:base_url` / `:model`
options and `TYPESAFE_BASE_URL` / `TYPESAFE_DEFAULT_MODEL` overrides still apply. Anyone with
a `TYPESAFE_API_KEY` sees zero behaviour change.

## Errors

Every failure is a `%TypeSafe.Error{}`. Match on its `:type`:

```elixir
case TypeSafe.ask(client, ticket.body, questions) do
  {:ok, response} ->
    handle(response)

  {:error, %TypeSafe.Error{type: :rate_limited, retry_after_ms: ms}} ->
    schedule_retry(ticket, ms)

  {:error, %TypeSafe.Error{type: :invalid_request} = error} ->
    # A bug in how the questions were built: fail loudly.
    raise error

  {:error, %TypeSafe.Error{} = error} ->
    Logger.error(Exception.message(error))
end
```

Questions are validated before anything is sent. A problem returns an `:invalid_request` error
whose `path` points at the offending value, such as `["questions", "rating", "criteria"]`.
HTTP and transport failures map to `:bad_request`, `:authentication`, `:permission_denied`,
`:not_found`, `:unprocessable`, `:rate_limited`, `:overloaded`, `:server`, `:api`,
`:transport` and `:timeout`. A 2xx body that fails decoding is `:invalid_response`.
`TypeSafe.ask!/4` raises the same struct. `Exception.message/1` renders one log-ready line:

```text
bad_request (HTTP 400): Unknown model: jev-0.0.1 [endpoint: POST https://api.typesafe.ai/v1/systemone, request_id: req_01a0ac9bf8bb77ce96b208891a67036e]
```

See `TypeSafe.Error` for the full table and fields.

## Retries

The default policy matches TypeSafe's official Python and JavaScript SDKs. It makes 2 retries after the
first attempt, with exponential backoff from 500 ms to a 5 s cap and 25% jitter. It retries
408, 429 and every 5xx (including 529 Overloaded), plus connection failures and timeouts. It
honours `Retry-After`, and the whole call has a 30 s budget.

```elixir
TypeSafe.new(retry: [max_retries: 4, budget_ms: 60_000])  # per client
TypeSafe.ask(client, state, questions, retry: false)      # per call
```

A per-call keyword list merges over the client's policy; a `%TypeSafe.Retry{}` or `false`
replaces it.

`TypeSafe.Error.retryable?/2` exposes the same predicate for your own escalation logic. See
`TypeSafe.Retry`.

## Telemetry

Each call emits one `[:typesafe, :request, :start]` event and one `:stop` event (or
`:exception`). The `:stop` event carries duration, token usage, status, request id, the retry
count and the error, if any. See the [Telemetry guide](guides/telemetry.md) and
`TypeSafe.Telemetry`.

## Testing

Route TypeSafe through `Req.Test` in `config/test.exs`, then stub answers per test:

```elixir
# config/test.exs
config :typesafe,
  api_key: "test",
  retry: false,
  req_options: [plug: {Req.Test, TypeSafe}]
```

```elixir
TypeSafe.Test.stub_answers(%{
  is_urgent: {:noul, 0.92},
  department: {:choice, :technical, %{billing: 0.08, technical: 0.85, sales: 0.07}, 0.82}
})
```

Tests run offline with `async: true`. See the [Testing guide](guides/testing.md) and
`TypeSafe.Test`.

## Guides

- [Getting started](guides/getting-started.md)
- [Questions](guides/questions.md): the three primitives, criteria shapes, structured JSON and
  validation
- [Confidence](guides/confidence.md): probabilities, confidence and thresholds in your own code
- [Batching and concurrency](guides/batching.md): many questions per request, many requests
  per second
- [Testing](guides/testing.md)
- [Telemetry](guides/telemetry.md)
- [Cheatsheet](cheatsheets/typesafe.cheatmd)

Also included:

- `TypeSafe.Req` attaches TypeSafe to a `Req.Request` you already own.
- `mix typesafe.schema` writes the request and response JSON Schemas for use outside Elixir.

Links: [HexDocs](https://hexdocs.pm/typesafe) ·
[TypeSafe documentation](https://docs.typesafe.ai) ·
[HTTP API reference](https://docs.typesafe.ai/api.md) · [Changelog](CHANGELOG.md)

## License

MIT. See the `LICENSE` file.
