defmodule SpectreKinetic do
  @moduledoc """
  Elixir wrapper around the Rust `spectre-kinetic-engine`.
  """

  alias SpectreKinetic.Action
  alias SpectreKinetic.ActionChain
  alias SpectreKinetic.Dictionary
  alias SpectreKinetic.Extractor
  alias SpectreKinetic.Parser
  alias SpectreKinetic.Prompt
  alias SpectreKinetic.Server

  @type plan_option ::
          {:slots, map()}
          | {:top_k, pos_integer()}
          | {:confidence, float()}
          | {:confidence_threshold, float()}
          | {:tool_threshold, float()}
          | {:mapping_threshold, float()}

  @doc """
  Returns a child spec for running the supervised dispatcher server.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts the supervised dispatcher wrapper around the Rust planner handle.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts \\ []), to: Server

  @doc """
  Plans one AL instruction and returns one `%SpectreKinetic.Action{}` result.
  """
  @spec plan(GenServer.server(), binary(), [plan_option()]) ::
          {:ok, Action.t()} | {:error, term()}
  def plan(server \\ Server, al_text, opts \\ []) when is_binary(al_text) and is_list(opts) do
    Server.plan(server, al_text, opts)
  end

  @doc """
  Plans from an explicit request map containing `al`, optional `slots`, and thresholds.
  """
  @spec plan_request(GenServer.server(), map()) :: {:ok, Action.t()} | {:error, term()}
  def plan_request(server \\ Server, request) when is_map(request) do
    Server.plan_request(server, request)
  end

  @doc """
  Plans from a JSON-encoded request payload.
  """
  @spec plan_json(GenServer.server(), binary()) :: {:ok, Action.t()} | {:error, term()}
  def plan_json(server \\ Server, request_json) when is_binary(request_json) do
    Server.plan_json(server, request_json)
  end

  @doc """
  Extracts and plans multiple AL instructions, preserving execution order.
  """
  @spec plan_chain(GenServer.server(), binary() | [binary()], [plan_option()]) ::
          {:ok, ActionChain.t()}
  def plan_chain(server \\ Server, text_or_lines, opts \\ [])

  def plan_chain(server, text, opts) when is_binary(text) and is_list(opts) do
    scan = Extractor.scan(text)
    {:ok, build_chain_from_scan(server, scan, opts)}
  end

  def plan_chain(server, al_lines, opts) when is_list(al_lines) and is_list(opts) do
    {:ok, build_chain(server, al_lines, opts)}
  end

  @doc """
  Adds one tool definition to the active in-memory registry.
  """
  @spec add_action(GenServer.server(), map()) :: :ok | {:error, term()}
  defdelegate add_action(server, action), to: Server

  @doc """
  Deletes one tool definition from the active in-memory registry.
  """
  @spec delete_action(GenServer.server(), binary()) :: {:ok, boolean()} | {:error, term()}
  defdelegate delete_action(server, action_id), to: Server

  @doc """
  Reloads the compiled registry from disk.
  """
  @spec reload_registry(GenServer.server(), binary()) :: :ok | {:error, term()}
  defdelegate reload_registry(server, registry_path), to: Server

  @doc """
  Returns the current number of active tools in the registry.
  """
  @spec action_count(GenServer.server()) :: non_neg_integer()
  defdelegate action_count(server), to: Server

  @doc """
  Returns the native crate version compiled into the NIF.
  """
  @spec version() :: binary()
  def version do
    SpectreKinetic.Native.version()
  end

  @doc """
  Extracts validated AL strings from a noisy text response.
  """
  @spec extract_al(binary()) :: {binary(), [binary()]}
  defdelegate extract_al(text), to: Extractor, as: :extract

  @doc """
  Extracts AL strings and returns validation diagnostics for malformed entries.
  """
  @spec extract_al_scan(binary()) :: Extractor.scan_result()
  defdelegate extract_al_scan(text), to: Extractor, as: :scan

  @doc """
  Parses one AL string into lightweight Elixir-side metadata.
  """
  @spec parse_al(binary()) :: Parser.parsed() | {:error, Parser.validation_error()}
  defdelegate parse_al(al_text), to: Parser, as: :parse

  @doc """
  Normalizes one AL string by unwrapping common LLM wrappers and collapsing whitespace.
  """
  @spec normalize_al(binary()) :: {:ok, binary()} | {:error, Parser.validation_error()}
  defdelegate normalize_al(al_text), to: Parser, as: :normalize

  @doc """
  Validates one AL string after normalization.
  """
  @spec validate_al(binary()) :: {:ok, binary()} | {:error, Parser.validation_error()}
  defdelegate validate_al(al_text), to: Parser, as: :validate

  @doc """
  Builds a scoped dictionary struct from a registry JSON file.
  """
  @spec dictionary(keyword()) :: {:ok, Dictionary.t()} | {:error, term()}
  def dictionary(opts \\ []), do: Dictionary.build(opts)

  @doc """
  Builds a scoped dictionary struct and raises on failure.
  """
  @spec dictionary!(keyword()) :: Dictionary.t()
  def dictionary!(opts \\ []), do: Dictionary.build!(opts)

  @doc """
  Builds compact dictionary text for LLM prompting.
  """
  @spec dictionary_text(keyword()) :: {:ok, binary()} | {:error, term()}
  def dictionary_text(opts \\ []), do: Dictionary.text(opts)

  @doc """
  Builds compact dictionary text for LLM prompting and raises on failure.
  """
  @spec dictionary_text!(keyword()) :: binary()
  def dictionary_text!(opts \\ []), do: Dictionary.text!(opts)

  @doc """
  Builds an LLM-facing AL prompt using a scoped registry dictionary.
  """
  @spec al_prompt(keyword()) :: {:ok, binary()} | {:error, term()}
  def al_prompt(opts \\ []), do: Prompt.build(opts)

  @doc """
  Builds an LLM-facing AL prompt and raises on failure.
  """
  @spec al_prompt!(keyword()) :: binary()
  def al_prompt!(opts \\ []), do: Prompt.build!(opts)

  @doc """
  Renders an LLM-facing AL prompt from a prebuilt dictionary.
  """
  @spec render_al_prompt(Dictionary.t(), keyword()) :: binary()
  def render_al_prompt(%Dictionary{} = dictionary, opts \\ []),
    do: Prompt.render(dictionary, opts)

  defp build_chain(server, al_lines, opts) do
    ActionChain.new(%{actions: plan_many(server, al_lines, opts)})
  end

  defp build_chain_from_scan(server, scan, opts) do
    actions =
      scan.entries
      |> Enum.with_index()
      |> Enum.map(&plan_scan_entry(server, &1, opts))

    ActionChain.new(%{actions: actions})
  end

  defp plan_many(server, al_lines, opts) do
    al_lines
    |> Enum.with_index()
    |> Enum.map(&plan_step(server, &1, opts))
  end

  defp plan_step(server, {al, index}, opts) do
    case plan(server, al, opts) do
      {:ok, %Action{} = action} -> %{action | index: index}
      {:error, reason} -> Action.error(al, reason, index)
    end
  end

  defp plan_scan_entry(server, {%{al: al}, index}, opts) when is_binary(al),
    do: plan_step(server, {al, index}, opts)

  defp plan_scan_entry(_server, {%{raw: raw, error: reason}, index}, _opts),
    do: Action.error(raw, reason, index)
end
