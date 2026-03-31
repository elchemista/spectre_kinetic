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

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  defdelegate start_link(opts \\ []), to: Server

  @spec plan(GenServer.server(), binary(), [plan_option()]) ::
          {:ok, Action.t()} | {:error, term()}
  def plan(server \\ Server, al_text, opts \\ []) when is_binary(al_text) and is_list(opts) do
    Server.plan(server, al_text, opts)
  end

  @spec plan_request(GenServer.server(), map()) :: {:ok, Action.t()} | {:error, term()}
  def plan_request(server \\ Server, request) when is_map(request) do
    Server.plan_request(server, request)
  end

  @spec plan_json(GenServer.server(), binary()) :: {:ok, Action.t()} | {:error, term()}
  def plan_json(server \\ Server, request_json) when is_binary(request_json) do
    Server.plan_json(server, request_json)
  end

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

  defdelegate add_action(server, action), to: Server
  defdelegate delete_action(server, action_id), to: Server
  defdelegate reload_registry(server, registry_path), to: Server
  defdelegate action_count(server), to: Server

  def version do
    SpectreKinetic.Native.version()
  end

  defdelegate extract_al(text), to: Extractor, as: :extract
  defdelegate extract_al_scan(text), to: Extractor, as: :scan
  defdelegate parse_al(al_text), to: Parser, as: :parse
  defdelegate normalize_al(al_text), to: Parser, as: :normalize
  defdelegate validate_al(al_text), to: Parser, as: :validate

  def dictionary(opts \\ []), do: Dictionary.build(opts)
  def dictionary!(opts \\ []), do: Dictionary.build!(opts)
  def dictionary_text(opts \\ []), do: Dictionary.text(opts)
  def dictionary_text!(opts \\ []), do: Dictionary.text!(opts)
  def al_prompt(opts \\ []), do: Prompt.build(opts)
  def al_prompt!(opts \\ []), do: Prompt.build!(opts)

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
