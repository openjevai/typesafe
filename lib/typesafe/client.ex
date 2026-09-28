defmodule TypeSafe.Client do
  @schema Zoi.keyword(
            [
              api_key:
                [description: "API key sent as `Authorization: Bearer <key>`. Env: `TYPESAFE_API_KEY`. Required."]
                |> Zoi.string()
                |> Zoi.min(1),
              base_url:
                [description: "API base URL. Env: `TYPESAFE_BASE_URL`."]
                |> Zoi.string()
                |> Zoi.refine({TypeSafe.Client, :validate_base_url, []})
                |> Zoi.default("https://api.typesafe.ai"),
              model:
                [description: "Default model for `TypeSafe.ask/4`. Env: `TYPESAFE_DEFAULT_MODEL`."]
                |> Zoi.string()
                |> Zoi.min(1)
                |> Zoi.default("jev-latest"),
              timeout:
                [
                  description:
                    "Receive timeout in milliseconds for each HTTP operation; the connect timeout comes from the Finch pool."
                ]
                |> Zoi.integer()
                |> Zoi.positive()
                |> Zoi.default(10_000),
              retry:
                [
                  description:
                    "A `TypeSafe.Retry` struct, retry options as a keyword list, or `false` to disable retries."
                ]
                |> Zoi.any()
                |> Zoi.transform({TypeSafe.Client, :cast_retry, []})
                |> Zoi.default(%TypeSafe.Retry{}),
              headers:
                [
                  description:
                    "Extra request headers as a map or list of `{name, value}`. Names are downcased, and atom names use dashes (`:x_team` becomes `x-team`). Identification and auth headers cannot be overridden."
                ]
                |> Zoi.any()
                |> Zoi.transform({TypeSafe.Client, :cast_headers, []})
                |> Zoi.default([]),
              finch:
                Zoi.keyword(Zoi.any(),
                  description:
                    "Req's `:finch` options, such as `[name: MyApp.Finch]` to use your own pool with its own connect timeout."
                ),
              req_options:
                Zoi.any()
                |> Zoi.keyword(
                  description:
                    "Req options merged last, such as `[plug: {Req.Test, TypeSafe}]` in tests. App config and explicit values are merged. `:retry_delay` is rejected while `:retry` is a policy."
                )
                |> Zoi.default([])
            ],
            unrecognized_keys: :error
          )

  @moduledoc """
  A TypeSafe client: a `Req.Request` plus the resolved options it was built from.

  A client is an immutable value. Build it at runtime (it cannot live in a module attribute,
  because the underlying request holds functions), for example once in a function your code
  calls or in a process that starts with your application, then pass it along and share it
  across processes; it holds no process state and needs no supervision.

      client = TypeSafe.new(api_key: System.fetch_env!("TYPESAFE_API_KEY"))

  ## Options

  #{Zoi.describe(@schema)}

  ## Resolution order

  Each option resolves from, in order:

    1. the option passed to `new/1`,
    2. its `TYPESAFE_*` environment variable (for `api_key`, `base_url` and `model`; blank
       values are ignored, as in TypeSafe's official Python and JavaScript SDKs),
    3. `config :typesafe, <option>` application config,
    4. the default.

  A missing API key raises `ArgumentError` from `new/1`, never at request time.

  ## OpenJEV provider

  [OpenJEV](https://openjev.sh) is a free community gateway to the same Jev model.
  TypeSafe stays the default; OpenJEV is opt-in:

    1. `JEV_PROVIDER=openjev` (or `provider: :openjev`) selects OpenJEV explicitly.
    2. Otherwise, if `TYPESAFE_API_KEY` is set, TypeSafe is used (unchanged default).
    3. Otherwise, if only `OPENJEV_API_KEY` is set, OpenJEV is used.

  When OpenJEV is selected, the API key comes from `OPENJEV_API_KEY` (unless an explicit
  `:api_key` was passed), `base_url` defaults to `https://api.openjev.sh` and `model`
  defaults to `"openjev"`. Explicit `:base_url` / `:model` options and `TYPESAFE_BASE_URL`
  / `TYPESAFE_DEFAULT_MODEL` overrides still apply.

  `TYPESAFE_LOG_LEVEL` is intentionally not read: configure Elixir's `Logger` instead. Retries
  are logged by Req at `:debug`; the `:retries` count on the `[:typesafe, :request, :stop]`
  telemetry event is the intended signal.

  ## Transport

  The underlying `Req.Request` is kept in the `:req` field. Every call runs on a copy with the
  call's options merged in, so you can add Req steps or swap adapters through `:req_options`
  without the SDK getting in the way. Requests use Req's default HTTP/1 Finch pool unless you
  pass `:finch`.

  `:timeout` (on the client or per call) only sets Req's `:receive_timeout`. The client never
  sets `:connect_options`, because every distinct set of connect options starts a new Finch
  pool, and Req refuses `:connect_options` together with `:finch`. For a connect timeout,
  start your own pool and pass `finch: [name: MyApp.Finch]`, or pass
  `req_options: [connect_options: [timeout: 5_000]]`.

  Req's response body decoding is turned off (`decode_body: false`); the SDK decodes bodies
  itself, as JSON when they parse and as text otherwise, so a malformed body behaves the same
  on every supported Req version.

  The retry policy computes its own delays, so `:retry_delay` cannot be combined with it:
  `new/1` raises when `:req_options` sets `:retry_delay` while `:retry` is a policy, and a
  `:retry_delay` set through `Req.default_options/1` is ignored. Use
  `retry: [backoff_initial_ms: 0]` for instant retries.

  The `authorization`, `accept`, `user-agent`, `x-typesafe-sdk`, `x-typesafe-runtime` and
  `x-typesafe-retry-count` headers are set on every attempt and cannot be overridden through
  `:headers`, as in TypeSafe's official Python and JavaScript SDKs.
  """

  alias TypeSafe.Error
  alias TypeSafe.Retry

  @derive {Inspect, except: [:api_key, :req]}
  @enforce_keys [:req, :api_key, :base_url, :model, :timeout, :retry]
  defstruct [:req, :api_key, :base_url, :model, :timeout, :retry, :finch, headers: [], req_options: []]

  @type t :: %__MODULE__{
          req: Req.Request.t(),
          api_key: String.t(),
          base_url: String.t(),
          model: String.t(),
          timeout: pos_integer(),
          retry: Retry.t() | false,
          headers: [{String.t(), String.t()}],
          finch: keyword() | nil,
          req_options: keyword()
        }

  @typedoc false
  @type info :: %{
          status: pos_integer() | nil,
          request_id: String.t() | nil,
          retries: non_neg_integer(),
          endpoint: String.t()
        }

  @version Mix.Project.config()[:version]
  # Deliberately not "typesafe-sdk", the identifier TypeSafe's official SDKs send: this client is
  # not one of them, and its traffic should not be attributed to them.
  @sdk "typesafe-elixir/#{@version}"

  @env_vars %{
    api_key: "TYPESAFE_API_KEY",
    base_url: "TYPESAFE_BASE_URL",
    model: "TYPESAFE_DEFAULT_MODEL",
    provider: "JEV_PROVIDER",
    openjev_api_key: "OPENJEV_API_KEY"
  }

  # OpenJEV (https://openjev.sh) is a free community gateway to the same Jev model that
  # TypeSafe serves. These defaults are used when the OpenJEV provider is selected.
  @openjev_base_url "https://api.openjev.sh"
  @openjev_model "openjev"
  @protected_headers ~w(authorization accept user-agent x-typesafe-sdk x-typesafe-runtime x-typesafe-retry-count)

  @call_schema Zoi.keyword(
                 [
                   timeout: Zoi.positive(Zoi.integer()),
                   retry: Zoi.transform(Zoi.any(), {TypeSafe.Client, :cast_retry, []}),
                   headers: Zoi.transform(Zoi.any(), {TypeSafe.Client, :cast_headers, []})
                 ],
                 unrecognized_keys: :strip
               )

  @doc """
  Builds a client, resolving and validating every option.

  Raises `ArgumentError` when the API key is missing or an option is invalid.

      iex> client = TypeSafe.Client.new(api_key: "ts_test_key", model: "jev-preview")
      iex> {client.model, client.base_url, client.timeout}
      {"jev-preview", "https://api.typesafe.ai", 10000}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ [])

  def new(opts) when not is_list(opts) do
    raise ArgumentError, "expected TypeSafe options as a keyword list, got: #{inspect(opts)}"
  end

  def new(opts) do
    if !Keyword.keyword?(opts),
      do: raise(ArgumentError, "expected TypeSafe options as a keyword list, got: #{inspect(opts)}")

    resolved = resolve(opts)

    if is_nil(resolved[:api_key]) do
      raise ArgumentError,
            "no TypeSafe API key: pass :api_key to TypeSafe.new/1, set the TYPESAFE_API_KEY environment variable, " <>
              "or set OPENJEV_API_KEY (with JEV_PROVIDER=openjev) to use OpenJEV, " <>
              "or configure `config :typesafe, api_key: ...`"
    end

    # Zoi crashes on a list that is not a keyword list, so those are rejected here.
    for key <- [:finch, :req_options], value = resolved[key], not Keyword.keyword?(value) do
      raise ArgumentError, "invalid TypeSafe options: expected a keyword list, at #{key}"
    end

    parsed =
      case Zoi.parse(@schema, resolved) do
        {:ok, parsed} -> parsed
        {:error, errors} -> raise ArgumentError, "invalid TypeSafe options: " <> Zoi.prettify_errors(errors)
      end

    if match?(%Retry{}, parsed[:retry]) and Keyword.has_key?(parsed[:req_options], :retry_delay) do
      raise ArgumentError,
            "invalid TypeSafe options: :retry_delay in :req_options conflicts with the TypeSafe retry policy, " <>
              "which computes its own delays; use `retry: [backoff_initial_ms: 0]` for instant retries, " <>
              "or `retry: false` to leave retries to Req"
    end

    client = %__MODULE__{
      req: nil,
      api_key: parsed[:api_key],
      base_url: String.trim_trailing(parsed[:base_url], "/"),
      model: parsed[:model],
      timeout: parsed[:timeout],
      retry: parsed[:retry],
      headers: parsed[:headers],
      finch: parsed[:finch],
      req_options: parsed[:req_options]
    }

    %{client | req: build_req(client)}
  end

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Sends a request to any TypeSafe endpoint with the client's auth, headers, timeout and retry
  policy, returning the `Req.Response` for a 2xx status.

  This is an escape hatch for endpoints the SDK does not wrap yet; prefer `TypeSafe.ask/4` and
  `TypeSafe.list_models/2`. Non-2xx statuses and transport failures come back as
  `{:error, %TypeSafe.Error{}}`. The response body is decoded as JSON when it parses and left
  as text otherwise (an empty body stays `""`), whatever the `content-type`.

  ## Options

    * `:method` - the HTTP method, default `:get`.
    * `:url` - the path, such as `"/v1/models"`. Required.
    * `:json` - a term to encode as the JSON request body.
    * `:timeout`, `:retry`, `:headers` - per-call overrides of the client options, as for
      `TypeSafe.ask/4`.

  ## Examples

      iex> TypeSafe.Test.stub_models([%{name: "jev-latest", description: "Latest"}])
      iex> client = TypeSafe.new(api_key: "ts_test_key", req_options: [plug: {Req.Test, TypeSafe}])
      iex> {:ok, response} = TypeSafe.Client.request(client, url: "/v1/models")
      iex> response.status
      200
      iex> response.body["models"]
      [%{"name" => "jev-latest", "description" => "Latest", "release_date" => "2026-01-01"}]

      iex> TypeSafe.Test.stub_error(404)
      iex> client = TypeSafe.new(api_key: "ts_test_key", req_options: [plug: {Req.Test, TypeSafe}])
      iex> {:error, error} = TypeSafe.Client.request(client, method: :delete, url: "/v1/nope")
      iex> {error.type, error.status, error.endpoint}
      {:not_found, 404, "DELETE https://api.typesafe.ai/v1/nope"}
  """
  @spec request(t(), keyword()) :: {:ok, Req.Response.t()} | {:error, Error.t()}
  def request(%__MODULE__{} = client, opts) when is_list(opts) do
    case Keyword.keys(opts) -- [:method, :url, :json, :timeout, :retry, :headers] do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown options #{inspect(unknown)} for TypeSafe.Client.request/2"
    end

    {method, opts} = Keyword.pop(opts, :method, :get)
    {url, opts} = Keyword.pop(opts, :url)
    {json, opts} = Keyword.pop(opts, :json, :none)

    if !is_binary(url), do: raise(ArgumentError, "TypeSafe.Client.request/2 requires a :url path")

    body =
      case json do
        :none ->
          {:ok, nil}

        term ->
          case TypeSafe.JSON.encode(term) do
            {:ok, iodata} ->
              {:ok, iodata}

            {:error, exception} ->
              {:error, Error.invalid_request("request body is not valid JSON: " <> Exception.message(exception))}
          end
      end

    with {:ok, body} <- body,
         {{:ok, response}, _info} <- run(client, method, url, body, opts) do
      {:ok, %{response | body: decode_response_body(response.body)}}
    else
      {{:error, error}, _info} -> {:error, error}
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  # Runs one call (with retries) and returns `{result, info}`, where info carries the final
  # status, request id and retry count for telemetry, and the endpoint for error context. A 2xx
  # response keeps its raw body; decode it with `decode_body/1`.
  @spec run(t(), atom(), String.t(), iodata() | nil, keyword()) ::
          {{:ok, Req.Response.t()} | {:error, Error.t()}, info()}
  def run(%__MODULE__{} = client, method, path, body, call_opts) do
    call_opts = call_opts |> parse_call_opts!() |> merge_call_retry(client, call_opts)
    ref = make_ref()
    endpoint = "#{method |> to_string() |> String.upcase()} #{client.base_url}#{path}"

    req =
      client.req
      |> Req.merge(call_req_options(call_opts))
      |> drop_retry_delay(call_opts)
      |> Req.merge(method: method, url: path)
      |> put_body(body)
      |> Req.Request.put_private(:typesafe_ref, ref)
      |> Retry.put_started_at()

    try do
      result = request_with_pool_errors(req)
      info = %{status: nil, request_id: nil, retries: Process.get({__MODULE__, ref}, 0), endpoint: endpoint}

      case result do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          {{:ok, response}, %{info | status: status, request_id: Error.request_id(response.headers)}}

        {:ok, %Req.Response{status: status} = response} ->
          error = Error.from_response(status, decode_body(response.body), response.headers, endpoint)
          {{:error, error}, %{info | status: status, request_id: error.request_id}}

        {:error, exception} ->
          {{:error, Error.from_exception(exception, endpoint)}, info}
      end
    after
      Process.delete({__MODULE__, ref})
    end
  end

  # Finch raises (rather than returning an error) when no pooled connection frees up within
  # `pool_timeout`. That is a transient transport condition, so it is returned as an error
  # instead of crashing the caller, for example inside `Task.async_stream/3`. Every other
  # exception propagates unchanged.
  defp request_with_pool_errors(req) do
    Req.request(req)
  rescue
    exception in RuntimeError ->
      if String.starts_with?(exception.message, "Finch was unable to provide a connection") do
        {:error, %Error{type: :transport, reason: :pool_timeout, message: String.trim(exception.message)}}
      else
        reraise exception, __STACKTRACE__
      end
  end

  @doc false
  # Validates per-call transport options (`:timeout`, `:retry`, `:headers`), raising
  # `ArgumentError` for invalid values.
  @spec validate_call_opts!(keyword()) :: keyword()
  def validate_call_opts!(opts), do: parse_call_opts!(opts)

  @doc false
  # TypeSafe requests turn off Req's body decoding, so bodies are decoded here: JSON when the
  # body parses, the text otherwise, and `nil` for an empty body. A body some other step already
  # decoded is returned unchanged.
  @spec decode_body(term()) :: term()
  def decode_body(""), do: nil

  def decode_body(body) when is_binary(body) do
    case TypeSafe.JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  def decode_body(body), do: body

  @doc false
  # Request step: sets the identification headers on every attempt, including retries, so
  # nothing merged later can override them, and records the retry count for telemetry. It only
  # touches TypeSafe calls: requests made by `run/5` (`:typesafe_ref`), and requests built from a
  # client's `:req` or prepared by `TypeSafe.Req` (`:typesafe_active`). Anything else sent through
  # a shared `Req.Request` passes through unchanged.
  @spec put_identification_headers(Req.Request.t()) :: Req.Request.t()
  def put_identification_headers(%Req.Request{} = request) do
    ref = Req.Request.get_private(request, :typesafe_ref)

    if ref || Req.Request.get_private(request, :typesafe_active) do
      retry_count = Req.Request.get_private(request, :req_retry_count, 0)
      if ref, do: Process.put({__MODULE__, ref}, retry_count)

      request =
        request
        |> Req.Request.put_header("accept", "application/json")
        |> Req.Request.put_header("user-agent", @sdk)
        |> Req.Request.put_header("x-typesafe-sdk", @sdk)
        |> Req.Request.put_header("x-typesafe-runtime", runtime())

      if retry_count > 0,
        do: Req.Request.put_header(request, "x-typesafe-retry-count", Integer.to_string(retry_count)),
        else: Req.Request.delete_header(request, "x-typesafe-retry-count")
    else
      request
    end
  end

  @doc """
  Returns the `X-TypeSafe-Runtime` header value, such as `"elixir/1.20.2 (otp/28; linux; x86_64)"`.
  """
  @spec runtime() :: String.t()
  def runtime do
    case :persistent_term.get({__MODULE__, :runtime}, nil) do
      nil ->
        value = "elixir/#{System.version()} (otp/#{System.otp_release()}; #{os()}; #{arch()})"
        :persistent_term.put({__MODULE__, :runtime}, value)
        value

      value ->
        value
    end
  end

  @doc "Returns the SDK identifier sent in `User-Agent` and `X-TypeSafe-SDK`, such as `\"typesafe-elixir/#{@version}\"`."
  @spec sdk() :: String.t()
  def sdk, do: @sdk

  @doc false
  @spec protected_headers() :: [String.t()]
  def protected_headers, do: @protected_headers

  ## Option casting (used by the Zoi schemas)

  @doc false
  @spec cast_retry(term(), keyword()) :: {:ok, Retry.t() | false} | {:error, String.t()}
  def cast_retry(false, _opts), do: {:ok, false}

  def cast_retry(retry, _opts) when is_list(retry) or is_struct(retry, Retry) do
    {:ok, Retry.new(retry)}
  rescue
    exception in ArgumentError -> {:error, Exception.message(exception)}
  end

  def cast_retry(other, _opts),
    do: {:error, "expected a TypeSafe.Retry, a keyword list or false, got: #{inspect(other)}"}

  @doc false
  # Header names are downcased. Atom names follow Req's convention, with underscores turned into
  # dashes, so `x_team: "support"` sends `x-team`.
  @spec cast_headers(term(), keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def cast_headers(headers, _opts) when is_map(headers) or is_list(headers) do
    headers
    |> Enum.reduce_while({:ok, []}, fn
      {name, value}, {:ok, acc}
      when (is_binary(name) or is_atom(name)) and (is_binary(value) or is_number(value) or is_atom(value)) ->
        name = header_name(name)

        if name in @protected_headers,
          do: {:cont, {:ok, acc}},
          else: {:cont, {:ok, [{name, to_string(value)} | acc]}}

      other, _acc ->
        {:halt, {:error, "expected headers as {name, value} pairs, got: #{inspect(other)}"}}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  def cast_headers(other, _opts),
    do: {:error, "expected headers as a map or list of {name, value}, got: #{inspect(other)}"}

  @doc false
  @spec validate_base_url(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_base_url(url, _opts) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] and is_binary(host) and host != "" -> :ok
      _ -> {:error, "expected an http(s) URL, got: #{inspect(url)}"}
    end
  end

  ## Internals

  defp resolve(opts) do
    app_env = Application.get_all_env(:typesafe)

    schema_keys =
      [:api_key, :base_url, :model, :timeout, :retry, :headers, :finch, :req_options, :provider, :openjev_api_key]

    resolved =
      schema_keys
      |> Enum.reduce([], fn key, acc ->
        case resolve_option(key, opts, app_env) do
          nil -> acc
          value -> Keyword.put(acc, key, value)
        end
      end)
      |> Keyword.merge(Keyword.drop(opts, schema_keys))

    apply_provider(resolved, opts)
  end

  # OpenJEV (https://openjev.sh) is a free community gateway to the same Jev model that
  # TypeSafe serves. TypeSafe stays the default: an explicit `JEV_PROVIDER=openjev` (or
  # `:provider` option) selects OpenJEV; otherwise OpenJEV is used only when no TypeSafe
  # key is set but `OPENJEV_API_KEY` is. Anyone with a TypeSafe key sees zero behaviour change.
  defp apply_provider(resolved, opts) do
    case resolve_provider(resolved) do
      :typesafe ->
        resolved

      :openjev ->
        # An explicit `:api_key` passed to new/1 always wins; otherwise the key comes
        # from OPENJEV_API_KEY. base_url and model default to OpenJEV unless already set
        # via :base_url/TYPESAFE_BASE_URL or :model/TYPESAFE_DEFAULT_MODEL.
        api_key =
          if Keyword.has_key?(opts, :api_key),
            do: opts[:api_key],
            else: resolved[:openjev_api_key]

        resolved
        |> Keyword.put(:api_key, api_key)
        |> Keyword.put_new(:base_url, @openjev_base_url)
        |> Keyword.put_new(:model, @openjev_model)
    end
    |> Keyword.drop([:provider, :openjev_api_key])
  end

  defp resolve_provider(resolved) do
    explicit = resolved[:provider]

    cond do
      explicit in ["openjev", :openjev] -> :openjev
      explicit in ["typesafe", :typesafe] -> :typesafe
      is_nil(resolved[:api_key]) and not is_nil(resolved[:openjev_api_key]) -> :openjev
      true -> :typesafe
    end
  end

  # App config and explicit `:req_options` merge, so a test `plug:` in config survives an
  # explicit `req_options: [finch: ...]`. Every other option takes the first value present.
  # A value that is not a keyword list is passed through unmerged so the schema rejects it with
  # an ArgumentError.
  defp resolve_option(:req_options, opts, app_env) do
    config = app_env[:req_options]
    explicit = opts[:req_options]

    cond do
      is_nil(config) -> explicit
      is_nil(explicit) -> config
      not Keyword.keyword?(config) -> config
      not Keyword.keyword?(explicit) -> explicit
      true -> Keyword.merge(config, explicit)
    end
  end

  defp resolve_option(key, opts, app_env), do: first_present([opts[key], env(@env_vars[key]), app_env[key]])

  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))

  defp env(nil), do: nil

  defp env(var) do
    case System.get_env(var) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  defp build_req(%__MODULE__{} = client) do
    [
      base_url: client.base_url,
      auth: {:bearer, client.api_key},
      headers: client.headers,
      receive_timeout: client.timeout,
      decode_body: false
    ]
    |> Keyword.merge(if client.finch, do: [finch: client.finch], else: [])
    |> Keyword.merge(Retry.req_options(client.retry))
    |> Req.new()
    # `Req.new/1` applies `Req.default_options/0`. A global `:retry_delay` would make Req raise
    # once the policy returns `{:delay, ms}`, so it is dropped before the client's own options.
    |> Req.Request.delete_option(:retry_delay)
    # Every request built from `client.req` is a TypeSafe request, including one a caller sends
    # directly, so it always carries the identification headers.
    |> Req.Request.put_private(:typesafe_active, true)
    |> Req.Request.append_request_steps(typesafe_identification: &__MODULE__.put_identification_headers/1)
    |> Req.merge(client.req_options)
  end

  defp parse_call_opts!(opts) do
    case Zoi.parse(@call_schema, opts) do
      {:ok, parsed} -> parsed
      {:error, errors} -> raise ArgumentError, "invalid TypeSafe call options: " <> Zoi.prettify_errors(errors)
    end
  end

  # Per-call retry options as a keyword list merge over the client's policy (or over the defaults
  # when the client has `retry: false`); a policy struct or `false` replaces it.
  defp merge_call_retry(parsed, client, raw_opts) do
    case Keyword.fetch(raw_opts, :retry) do
      {:ok, retry} when is_list(retry) -> Keyword.put(parsed, :retry, Retry.merge(client.retry, retry))
      _other -> parsed
    end
  end

  defp call_req_options(call_opts) do
    Enum.flat_map(call_opts, fn
      {:timeout, timeout} -> [receive_timeout: timeout]
      {:retry, retry} -> Retry.req_options(retry)
      {:headers, headers} -> [headers: headers]
    end)
  end

  # A `:retry_delay` from `:req_options` is allowed when the client has `retry: false`, but a
  # per-call policy computes its own delays, so the option is dropped for that call.
  defp drop_retry_delay(req, call_opts) do
    case call_opts[:retry] do
      %Retry{} -> Req.Request.delete_option(req, :retry_delay)
      _other -> req
    end
  end

  defp decode_response_body(""), do: ""
  defp decode_response_body(body), do: decode_body(body)

  defp header_name(name) when is_atom(name),
    do: name |> Atom.to_string() |> String.replace("_", "-") |> String.downcase()

  defp header_name(name), do: String.downcase(name)

  defp put_body(req, nil), do: req

  defp put_body(req, body) do
    req
    |> Req.merge(body: body)
    |> Req.Request.put_header("content-type", "application/json")
  end

  defp os do
    case :os.type() do
      {:unix, name} -> Atom.to_string(name)
      {:win32, _} -> "windows"
    end
  end

  defp arch do
    :system_architecture |> :erlang.system_info() |> to_string() |> String.split("-") |> hd()
  end
end
