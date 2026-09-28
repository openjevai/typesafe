defmodule TypeSafe.Req do
  @moduledoc """
  A Req plugin for teams that already run their own `Req.Request`, with shared pools, tracing
  steps or custom adapters, and want to call TypeSafe through it instead of a second client.

      req =
        Req.new(finch: [name: MyApp.Finch])
        |> MyApp.Tracing.attach()
        |> TypeSafe.Req.attach(api_key: System.fetch_env!("TYPESAFE_API_KEY"))

      questions = %{is_urgent: TypeSafe.noul("Does this convey urgency?")}

      req
      |> Req.post(typesafe_state: "Help! My payouts are failing.", typesafe_questions: questions)
      |> TypeSafe.Req.decode(questions)
      #=> {:ok, %TypeSafe.Response{answers: %{is_urgent: %TypeSafe.Answer.Noul{noul: 0.93}}}}

  `attach/2` registers three request options:

    * `:typesafe_state` - the state to judge (a string, map or list).
    * `:typesafe_questions` - the questions, as for `TypeSafe.ask/4`.
    * `:typesafe_model` - the model for this request, overriding the one given to `attach/2`.

  ## TypeSafe requests

  A request with `:typesafe_questions` set is a TypeSafe request. A request step prepended by
  `attach/2` validates the questions, encodes the JSON body and makes it a `POST` with:

    * the API key as `Authorization: Bearer <key>`,
    * the retry policy given to `attach/2`,
    * the TypeSafe identification headers on every attempt,
    * Req's body decoding turned off, so `response.body` is the raw JSON text for `decode/2`,
    * the URL `base_url <> "/v1/systemone"`, where `base_url` is the one resolved by `attach/2`.
      A relative `:url` replaces the path (`url: "/v2/systemone"`), and an absolute `:url` is
      used as given. A `:base_url` set on the request itself is not used for TypeSafe requests.

  Invalid questions raise `TypeSafe.Error` from that step, since Req request steps cannot return
  errors on every supported Req version.

  Every other request through the same `Req.Request` is left alone: no API key, no TypeSafe
  headers and no TypeSafe retry policy, so attaching the plugin to a shared request cannot leak
  the key to another host or retry unrelated `POST` requests.

  ## Decoding

  Decoding is a plain function, `decode/2`, rather than a response step, because Req 0.8
  deprecates response and error steps. The response alone does not carry the request URL on
  every supported Req version, so errors from `decode/2` have `endpoint: nil`. Pass it the same
  questions so answer ids and Choice options map back to your keys.

  Unlike `TypeSafe.new/1`, the plugin does not emit `[:typesafe, :request, ...]` telemetry: your
  Req pipeline owns the call, and Finch already emits its own `[:finch, ...]` events.
  """

  alias TypeSafe.Client
  alias TypeSafe.Error
  alias TypeSafe.Question
  alias TypeSafe.Response
  alias TypeSafe.Retry

  @options [:typesafe_state, :typesafe_questions, :typesafe_model]
  @path "/v1/systemone"

  @doc """
  Attaches TypeSafe to a request.

  `attach/2` only registers the `:typesafe_*` options and adds two steps; it sets no options on
  the request. The API key, retry policy and identification headers apply to TypeSafe requests
  (those with `:typesafe_questions`) and to nothing else.

  ## Options

    * `:api_key` - resolved like `TypeSafe.new/1`: this option, then `TYPESAFE_API_KEY`, then
      `config :typesafe, :api_key`. Required.
    * `:base_url` - resolved the same way: this option, then `TYPESAFE_BASE_URL`, then
      `config :typesafe, :base_url`, then `https://api.typesafe.ai`.
    * `:model` - the default model, resolved the same way (default `"jev-latest"`).
    * `:provider` - `:openjev` to use [OpenJEV](https://openjev.sh), or `:typesafe`
      (default). Also set via `JEV_PROVIDER`. When OpenJEV is selected, the API key
      comes from `OPENJEV_API_KEY` (or `:openjev_api_key`) and the defaults are
      `https://api.openjev.sh` and model `"openjev"`.
    * `:openjev_api_key` - OpenJEV API key, resolved like `:api_key` for the OpenJEV
      provider. Also set via `OPENJEV_API_KEY`.
    * `:retry` - a `TypeSafe.Retry`, retry options, `false`, or `:keep` to leave the request's
      own retry settings alone. Defaults to the `TypeSafe.Retry` defaults, which retry `POST` requests
      on transient failures (Req's default only retries `GET` and `HEAD`). When a policy
      applies, a `:retry_delay` on the request is dropped for TypeSafe requests, since the
      policy computes its own delays.

  Raises `ArgumentError` when no API key is found or an option is invalid.

  ## Examples

      iex> req = Req.new(plug: {Req.Test, TypeSafe}) |> TypeSafe.Req.attach(api_key: "ts_test_key")
      iex> TypeSafe.Test.stub_answers(%{spam: {:noul, 0.1}})
      iex> questions = %{spam: TypeSafe.noul("Is this spam?")}
      iex> {:ok, response} = req |> Req.post(typesafe_state: "Buy now!", typesafe_questions: questions) |> TypeSafe.Req.decode(questions)
      iex> response.answers.spam.noul
      0.1
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = request, opts \\ []) do
    {retry, opts} = Keyword.pop(opts, :retry, %Retry{})

    unknown = Keyword.keys(opts) -- [:api_key, :base_url, :model, :provider, :openjev_api_key]
    if unknown != [], do: raise(ArgumentError, "unknown options #{inspect(unknown)} for TypeSafe.Req.attach/2")

    client =
      opts
      |> Keyword.take([:api_key, :base_url, :model, :provider, :openjev_api_key])
      |> Keyword.put(:retry, false)
      |> Client.new()
    retry = if retry == :keep, do: :keep, else: cast_retry!(retry)

    request
    |> Req.Request.register_options(@options)
    |> Req.Request.put_private(:typesafe_client, client)
    |> Req.Request.put_private(:typesafe_retry, retry)
    |> Req.Request.prepend_request_steps(typesafe_prepare: &__MODULE__.prepare/1)
    |> Req.Request.append_request_steps(typesafe_identification: &Client.put_identification_headers/1)
  end

  @doc """
  Decodes the result of a TypeSafe request made through an attached `Req.Request`.

  Accepts `{:ok, response}`, `{:error, exception}` or a bare `Req.Response`, and the questions
  that were sent, so ids and Choice options map back to your keys. The body may be the raw JSON
  text (as TypeSafe requests return it) or an already decoded term.

  A 2xx body that does not match the response schema returns an `:invalid_response` error with
  the response's status, request id, headers and body.

      iex> body = %{"model" => "jev-1.13.0", "answers" => %{"spam" => %{"type" => "noul", "noul" => 0.1}}, "usage" => %{}}
      iex> response = Req.Response.new(status: 200, body: body)
      iex> {:ok, decoded} = TypeSafe.Req.decode(response, %{spam: TypeSafe.noul("Is this spam?")})
      iex> decoded.answers.spam.noul
      0.1
  """
  @spec decode({:ok, Req.Response.t()} | {:error, Exception.t()} | Req.Response.t(), Question.questions()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def decode({:ok, %Req.Response{} = response}, questions), do: decode(response, questions)
  def decode({:error, exception}, _questions), do: {:error, Error.from_exception(exception, nil)}

  def decode(%Req.Response{status: status} = response, questions) when status in 200..299 do
    with {:ok, prepared} <- Question.prepare(questions) do
      case Response.from_wire(Client.decode_body(response.body), Error.request_id(response.headers), prepared) do
        {:error, %Error{type: :invalid_response} = error} -> {:error, Error.put_response(error, response, nil)}
        result -> result
      end
    end
  end

  def decode(%Req.Response{status: status} = response, _questions) do
    body = Client.decode_body(response.body)
    {:error, Error.from_response(status, body, response.headers, nil)}
  end

  @doc false
  # Request step: turns a request with `:typesafe_questions` into a TypeSafe request. Every
  # other request passes through untouched.
  @spec prepare(Req.Request.t()) :: Req.Request.t()
  def prepare(%Req.Request{} = request) do
    case Map.fetch(request.options, :typesafe_questions) do
      :error -> request
      {:ok, questions} -> prepare(request, questions)
    end
  end

  defp prepare(request, questions) do
    %Client{} = client = Req.Request.get_private(request, :typesafe_client)
    state = Map.get(request.options, :typesafe_state)
    model = request.options[:typesafe_model] || client.model

    case Question.build_request(state, model, questions) do
      {:ok, body, _prepared} ->
        %{request | method: :post, body: body, url: typesafe_url(request.url, client)}
        |> Req.Request.put_header("content-type", "application/json")
        |> Req.Request.merge_options(auth: {:bearer, client.api_key}, decode_body: false)
        |> put_retry(Req.Request.get_private(request, :typesafe_retry, %Retry{}))
        |> Req.Request.put_private(:typesafe_active, true)
        |> put_started_at()

      {:error, %Error{} = error} ->
        raise error
    end
  end

  # Retries re-run the request steps on Req 0.7, so the budget keeps the first attempt's stamp.
  defp put_started_at(request) do
    if Req.Request.get_private(request, :typesafe_started_at),
      do: request,
      else: Retry.put_started_at(request)
  end

  defp put_retry(request, :keep), do: request

  defp put_retry(request, retry) do
    request
    |> Req.Request.merge_options(Retry.req_options(retry))
    |> Req.Request.delete_option(:retry_delay)
  end

  defp typesafe_url(%URI{host: host} = url, _client) when is_binary(host), do: url

  defp typesafe_url(%URI{} = url, %Client{base_url: base_url}) do
    path =
      case url.path do
        path when path in [nil, "", "/"] -> @path
        "/" <> _ = path -> path
        path -> "/" <> path
      end

    URI.parse(base_url <> path <> if(url.query, do: "?" <> url.query, else: ""))
  end

  defp cast_retry!(retry) do
    case Client.cast_retry(retry, []) do
      {:ok, policy} -> policy
      {:error, message} -> raise ArgumentError, "invalid :retry for TypeSafe.Req.attach/2: " <> message
    end
  end
end
