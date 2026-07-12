defmodule SpectreKinetic do
  @moduledoc """
  Elixir-first planning toolkit for Action Language tool selection.
  """

  alias SpectreKinetic.Action
  alias SpectreKinetic.ActionChain
  alias SpectreKinetic.Adapter.Server, as: AdapterServer
  alias SpectreKinetic.Dictionary
  alias SpectreKinetic.Extractor
  alias SpectreKinetic.Parser
  alias SpectreKinetic.PlanFinalizer
  alias SpectreKinetic.Planner
  alias SpectreKinetic.Planner.Runtime, as: PlannerRuntime
  alias SpectreKinetic.Prompt
  alias SpectreKinetic.RuntimeConfig

  @max_chain_source_bytes 1_024 * 1_024
  @max_chain_step_bytes 32 * 1_024
  @max_chain_steps 128

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :al, persist: false)
      Module.register_attribute(__MODULE__, :spectre_tools, accumulate: true)
      @on_definition {SpectreKinetic, :__on_definition__}
      @before_compile SpectreKinetic
    end
  end

  @doc false
  def __on_definition__(env, kind, name, args, _guards, _body) do
    case Module.get_attribute(env.module, :al) do
      nil ->
        :ok

      al when kind != :def ->
        Module.delete_attribute(env.module, :al)

        raise ArgumentError,
              "@al can only annotate public functions, got #{kind} #{name}/#{length(args || [])} in #{inspect(env.module)} with #{inspect(al)}"

      al when is_binary(al) ->
        tool = %{
          function: name,
          arity: length(args || []),
          params: extract_tool_params(args || []),
          al: al,
          line: env.line
        }

        Module.put_attribute(env.module, :spectre_tools, tool)
        Module.delete_attribute(env.module, :al)

      other ->
        Module.delete_attribute(env.module, :al)

        raise ArgumentError,
              "@al must be a string for #{inspect(env.module)}.#{name}/#{length(args || [])}, got: #{inspect(other)}"
    end
  end

  defmacro __before_compile__(env) do
    tools =
      env.module
      |> Module.get_attribute(:spectre_tools)
      |> Enum.reverse()
      |> Macro.escape()

    quote do
      @doc false
      def __spectre_tools__, do: unquote(tools)
    end
  end

  @type plan_option ::
          {:slots, map()}
          | {:top_k, pos_integer()}
          | {:tool_threshold, float()}
          | {:mapping_threshold, float()}
          | {:tool_selection_fallback, :disabled | :reranker}
          | {:fallback_top_k, pos_integer()}
          | {:fallback_margin, float()}
          | {:reranker_threshold, float()}
          | {:classifiers, [module() | {module(), keyword()}]}

  @doc """
  Returns a child spec for running the supervised planner adapter.
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
  Starts the optional `GenServer` adapter over a planner runtime.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts \\ []), to: AdapterServer

  @doc """
  Plans one AL instruction against an explicit runtime or adapter target.
  """
  @spec plan(PlannerRuntime.t() | GenServer.server(), term()) ::
          {:ok, Action.t()} | {:error, term()}
  def plan(target, al_text), do: plan(target, al_text, [])

  @doc """
  Plans one AL instruction against an explicit runtime or adapter target.
  """
  @spec plan(PlannerRuntime.t() | GenServer.server(), term(), term()) ::
          {:ok, Action.t()} | {:error, term()}
  def plan(%PlannerRuntime{} = runtime, al_text, opts) do
    with :ok <- RuntimeConfig.validate_plan_input(al_text, opts) do
      opts = normalize_plan_opts(opts)
      mode = Keyword.get(opts, :__spectre_mode__, :plan)
      planner_reply(runtime, al_text, Planner.plan(runtime, al_text, opts), opts, mode)
    end
  end

  def plan(server, al_text, opts) do
    AdapterServer.plan(server, al_text, opts)
  end

  @doc """
  Plans from an explicit request map against an explicit runtime or adapter target.
  """
  @spec plan_request(PlannerRuntime.t() | GenServer.server(), term()) ::
          {:ok, Action.t()} | {:error, term()}
  def plan_request(%PlannerRuntime{} = runtime, request) do
    with :ok <- RuntimeConfig.validate_request(request) do
      normalized = RuntimeConfig.normalize_request(request)

      planner_reply(
        runtime,
        normalized["al"],
        Planner.plan_request(runtime, request, []),
        [],
        :plan
      )
    end
  end

  def plan_request(server, request) do
    AdapterServer.plan_request(server, request)
  end

  @doc """
  Plans from a JSON-encoded request payload against an explicit runtime or adapter target.
  """
  @spec plan_json(PlannerRuntime.t() | GenServer.server(), term()) ::
          {:ok, Action.t()} | {:error, term()}
  def plan_json(%PlannerRuntime{} = runtime, request_json) do
    with {:ok, request} <- RuntimeConfig.decode_request_json(request_json) do
      plan_request(runtime, request)
    end
  end

  def plan_json(server, request_json) do
    AdapterServer.plan_json(server, request_json)
  end

  @doc """
  Extracts and plans multiple AL instructions, preserving execution order.
  """
  @spec plan_chain(PlannerRuntime.t() | GenServer.server(), binary() | [binary()], [plan_option()]) ::
          {:ok, ActionChain.t()} | {:error, term()}
  def plan_chain(target, text_or_lines, opts \\ [])

  def plan_chain(target, text, opts) when is_binary(text) do
    with :ok <- RuntimeConfig.validate_options(opts),
         :ok <- validate_chain_source(text) do
      opts = normalize_plan_opts(opts)
      scan = Extractor.scan(text)
      {:ok, build_chain_from_scan(target, scan, opts)}
    end
  end

  def plan_chain(target, al_lines, opts) when is_list(al_lines) do
    with :ok <- RuntimeConfig.validate_options(opts),
         :ok <- validate_chain_lines(al_lines) do
      {:ok, build_chain(target, al_lines, normalize_plan_opts(opts))}
    end
  end

  def plan_chain(_target, _text_or_lines, _opts),
    do: chain_validation_error(:must_be_binary_or_list)

  @doc """
  Adds one tool definition to the active in-memory registry.
  """
  @spec add_action(GenServer.server() | PlannerRuntime.t(), map()) ::
          :ok | {:error, term()} | {:ok, PlannerRuntime.t()}
  def add_action(%PlannerRuntime{} = runtime, action) do
    PlannerRuntime.add_action(runtime, action)
  end

  def add_action(server, action), do: AdapterServer.add_action(server, action)

  @doc """
  Deletes one tool definition from the active in-memory registry.
  """
  @spec delete_action(GenServer.server() | PlannerRuntime.t(), binary()) ::
          {:ok, boolean()} | {:error, term()} | {:ok, boolean(), PlannerRuntime.t()}
  def delete_action(%PlannerRuntime{} = runtime, action_id) do
    PlannerRuntime.delete_action(runtime, action_id)
  end

  def delete_action(server, action_id), do: AdapterServer.delete_action(server, action_id)

  @doc """
  Reloads the registry from disk.
  """
  @spec reload_registry(GenServer.server() | PlannerRuntime.t(), binary()) ::
          :ok | {:error, term()} | {:ok, PlannerRuntime.t()}
  def reload_registry(%PlannerRuntime{} = runtime, registry_path) do
    PlannerRuntime.reload_registry(runtime, registry_path)
  end

  def reload_registry(server, registry_path),
    do: AdapterServer.reload_registry(server, registry_path)

  @doc """
  Returns the current number of active tools in the registry.
  """
  @spec action_count(GenServer.server() | PlannerRuntime.t()) :: non_neg_integer()
  def action_count(%PlannerRuntime{} = runtime), do: PlannerRuntime.action_count(runtime)
  def action_count(server), do: AdapterServer.action_count(server)

  @doc """
  Loads a library-first planner runtime without starting the adapter.
  """
  @spec load_runtime(keyword()) :: {:ok, PlannerRuntime.t()} | {:error, term()}
  def load_runtime(opts \\ []), do: PlannerRuntime.load(opts)

  @doc """
  Loads a planner runtime and raises on failure.
  """
  @spec load_runtime!(keyword()) :: PlannerRuntime.t()
  def load_runtime!(opts \\ []), do: PlannerRuntime.load!(opts)

  @doc """
  Closes a library-first runtime and releases its registry resources.

  Call this from the same process that loaded the runtime. Supervised adapter
  runtimes are closed automatically with their server.
  """
  @spec close_runtime(PlannerRuntime.t()) :: :ok | {:error, term()}
  def close_runtime(%PlannerRuntime{} = runtime), do: PlannerRuntime.close(runtime)

  @doc """
  Returns the library version.
  """
  @spec version() :: binary()
  def version do
    :spectre_kinetic
    |> Application.spec(:vsn)
    |> to_string()
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

  defp build_chain(target, al_lines, opts) do
    ActionChain.new(%{actions: plan_many(target, al_lines, opts)})
  end

  defp build_chain_from_scan(target, scan, opts) do
    actions =
      scan.entries
      |> Enum.with_index()
      |> Enum.map(&plan_scan_entry(target, &1, opts))

    ActionChain.new(%{actions: actions})
  end

  defp plan_many(target, al_lines, opts) do
    al_lines
    |> Enum.with_index()
    |> Enum.map(&plan_step(target, &1, opts))
  end

  defp plan_step(target, {al, index}, opts) do
    opts = Keyword.put(opts, :__spectre_mode__, :plan_chain)

    case plan(target, al, opts) do
      {:ok, %Action{} = action} -> %{action | index: index}
      {:error, reason} -> Action.error(al, reason, index)
    end
  end

  defp plan_scan_entry(target, {%{al: al}, index}, opts) when is_binary(al),
    do: plan_step(target, {al, index}, opts)

  defp plan_scan_entry(_target, {%{raw: raw, error: reason}, index}, _opts),
    do: Action.error(raw, reason, index)

  defp planner_reply(runtime, al_text, planner_result, opts, mode),
    do: PlanFinalizer.to_action(runtime, al_text, planner_result, opts, mode)

  defp normalize_plan_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_plan_opts(opts), do: opts

  defp validate_chain_source(text) do
    cond do
      not String.valid?(text) -> chain_validation_error(:must_be_utf8_binary)
      byte_size(text) > @max_chain_source_bytes -> chain_validation_error(:exceeds_size_limit)
      true -> :ok
    end
  end

  defp validate_chain_lines(lines), do: validate_chain_lines(lines, 0, 0)
  defp validate_chain_lines([], _count, _total_bytes), do: :ok

  defp validate_chain_lines([_line | _rest], @max_chain_steps, _total_bytes),
    do: chain_validation_error(:too_many_steps)

  defp validate_chain_lines([line | rest], count, total_bytes) when is_binary(line) do
    next_total = total_bytes + byte_size(line)

    cond do
      not String.valid?(line) ->
        chain_validation_error(:must_contain_utf8_binaries)

      byte_size(line) > @max_chain_step_bytes or next_total > @max_chain_source_bytes ->
        chain_validation_error(:exceeds_size_limit)

      true ->
        validate_chain_lines(rest, count + 1, next_total)
    end
  end

  defp validate_chain_lines([_invalid | _rest], _count, _total_bytes),
    do: chain_validation_error(:must_contain_utf8_binaries)

  defp validate_chain_lines(_improper, _count, _total_bytes),
    do: chain_validation_error(:must_be_proper_list)

  defp chain_validation_error(reason),
    do: {:error, {:invalid_request, [%{field: :chain, reason: reason}]}}

  defp extract_tool_params(args) do
    args
    |> Enum.with_index(1)
    |> Enum.map(fn {arg, index} -> tool_param_name(arg, index) end)
  end

  defp tool_param_name({:\\, _, [arg, _default]}, index), do: tool_param_name(arg, index)

  defp tool_param_name({name, _, context}, _index) when is_atom(name) and is_atom(context),
    do: Atom.to_string(name)

  defp tool_param_name(_arg, index), do: "arg#{index}"
end
