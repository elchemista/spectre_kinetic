defmodule Spectre.Kinetic do
  @moduledoc """
  Stack integration for Action Language interpretation in Spectre core 0.4.1.

  Install this package in a `Spectre.Stack`, select that Stack on the Agent,
  and declare `use Spectre.Server, tools: MyApp.AI` on its Server. The
  typed installation generates the private `kinetic/3` helper. The scoped
  tool `{:kinetic, :interpret}` uses the same binding.

      install Spectre.Kinetic, actions: MyApp.Actions

  Generate with `planning: false`, then pass the consolidated model result to
  `kinetic(ctx, result, on_result: :prepared)`. Interpretation returns complete
  proposals through `handle_result/3`; it does not execute actions. Forward
  each proposal's arguments and metadata to the Server's `propose/4` helper.
  The host's governed binding then runs through GAM before capability release.

  The Stack configuration is immutable. It does not start a global planner.
  `actions:` mounts the annotated functions in your module. Omit it when
  another package supplies your action providers. Use the optional `mode:`
  to set a default effect classification and `modes:` to override individual
  actions.

  Use `SpectreKinetic` to parse and plan independently. See the
  [Governed Act Model](https://spectre.guide/en/governed-act-model) for the
  host authority and evidence boundary.
  """

  alias Spectre.Kinetic.{Extension, Planner, ServerTool}

  @version "0.2.0"
  @spectre_extension Module.concat(["Spectre", "Extension"])
  @spectre_integration Module.concat(["Spectre", "Integration"])

  @doc false
  def manifest do
    [
      id: :kinetic,
      module: __MODULE__,
      version: @version,
      contract: 1,
      spectre: "~> 0.4.1",
      provides: [{:service, :kinetic}],
      agent_extensions: [Extension],
      dsl: __MODULE__,
      metadata: %{role: :decision_interpreter}
    ]
  end

  @type classifier_config :: %{
          required(:module) => module(),
          required(:options) => keyword()
        }

  @doc """
  Declares the planner service and cognitive interpretation tool for Spectre 0.4.1.

  The Stack passes the compiled installation configuration. In a standalone
  application Spectre can be omitted and planning is available through
  `SpectreKinetic`.
  """
  @spec integration(stack_config()) :: struct()
  def integration(config) do
    planner_options = config |> Extension.stack_options() |> Extension.planner_options()

    tool_options = [
      args: [planning: :boolean, model_output: :string],
      description: "Prepare action proposals from unplanned, consolidated model output",
      helper: :kinetic,
      retry: :safe,
      max_bytes: 1_048_576
    ]

    integration = apply(@spectre_integration, :new, [])

    integration =
      apply(@spectre_integration, :service, [
        integration,
        Spectre.Action.Planner,
        Planner,
        planner_options
      ])

    apply(@spectre_integration, :tool, [integration, :interpret, ServerTool, tool_options])
  end

  @doc "Registers the closed action catalog for managed GAM execution; grants no authority."
  @spec effects(map()) :: map()
  def effects(config) do
    config
    |> Map.get(:options, [])
    |> Extension.action_providers()
    |> Enum.reduce(%{}, fn {provider, _module, opts}, effects ->
      actions_module = Keyword.fetch!(opts, :module)

      case Code.ensure_compiled(actions_module) do
        {:module, _} -> :ok
        {:error, reason} -> raise ArgumentError, "Kinetic actions unavailable: #{inspect(reason)}"
      end

      annotations = actions_module.__spectre_tools__()
      Map.merge(effects, Map.new(annotations, &effect_descriptor(&1, provider, opts)))
    end)
  end

  @spec effect_descriptor(map(), atom(), keyword()) :: {term(), map()}
  defp effect_descriptor(entry, provider, opts) do
    {{provider, entry.function},
     %{
       contract: 1,
       adapter: ServerTool,
       operation: entry.function,
       side_effect: :non_idempotent,
       material: :arguments,
       partition: [],
       schema_hash: nil,
       config: %{
         options: Keyword.put(opts, :provider_id, provider),
         annotation: entry
       }
     }}
  end

  @type stack_config :: %{
          required(:options) => keyword(),
          required(:classifiers) => [classifier_config()]
        }

  @doc false
  @spec compile(keyword(), Macro.t() | nil, Macro.Env.t()) :: {:ok, stack_config()}
  def compile(opts, block, caller) do
    stack_dsl = Module.concat(["Spectre", "Stack", "DSL"])

    classifiers =
      stack_dsl.compile!(block, caller, classifier: [1, 2])
      |> Enum.map(&classifier_config!/1)

    {:ok, %{options: opts, classifiers: classifiers}}
  end

  @doc """
  Returns the immutable Kinetic configuration bound to an Agent.
  """
  @spec config(module()) :: {:ok, keyword()} | {:error, term()}
  def config(agent) when is_atom(agent) do
    extension = Module.concat(["Spectre", "Extension"])

    with :ok <- ensure_spectre_extension(),
         {:ok, mount} <- extension.fetch(agent, :kinetic),
         config when is_list(config) <- mount.compiled do
      {:ok, config}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_kinetic_configuration}
    end
  end

  @spec ensure_spectre_extension() :: :ok | {:error, :spectre_not_loaded}
  defp ensure_spectre_extension do
    if Code.ensure_loaded?(@spectre_extension) and
         function_exported?(@spectre_extension, :fetch, 2),
       do: :ok,
       else: {:error, :spectre_not_loaded}
  end

  @spec classifier_config!({:classifier, [term()]}) :: classifier_config()
  defp classifier_config!({:classifier, [module]}), do: classifier_config!(module, [])

  defp classifier_config!({:classifier, [module, options]}),
    do: classifier_config!(module, options)

  @spec classifier_config!(term(), term()) :: classifier_config()
  defp classifier_config!(module, options)
       when is_atom(module) and not is_nil(module) and is_list(options) do
    if Keyword.keyword?(options) do
      %{module: module, options: options}
    else
      raise ArgumentError,
            "Spectre.Kinetic classifier options must be a keyword list, got: #{inspect(options)}"
    end
  end

  defp classifier_config!(module, options) do
    raise ArgumentError,
          "Spectre.Kinetic classifier must be a module with keyword options, got: " <>
            "#{inspect(module)}, #{inspect(options)}"
  end
end
