defmodule Spectre.Kinetic do
  @moduledoc """
  Stack package and legacy Agent integration for `SpectreKinetic`.

  Install Kinetic in a `Spectre.Stack` to declare the classifier pipeline used
  to interpret constrained decisions:

      install Spectre.Kinetic, mode: :closed_moves do
        classifier MyApp.IntentClassifier
        classifier MyApp.SafetyClassifier, threshold: 0.85
      end

  The Stack configuration is immutable data. Selecting it activates the
  Kinetic planner and, when `:actions` is configured, its built-in Action
  provider. It does not start a global planner or execute the selected
  decision. Kinetic owns interpretation; the Spectre core owns authorization
  and execution.

  The legacy Agent extension remains available:

      use Spectre.Agent
      use Spectre.Kinetic,
        actions: MyApp.Actions,
        runtime: MyApp.KineticRuntime

  `:actions` mounts the built-in `Spectre.Kinetic.Actions` provider, so the
  application does not need to implement an adapter. Omit it when other
  extensions, such as MCP or Lens, already contribute the providers that
  Kinetic should plan.

  Spectre keeps ownership of policy, persistence, and execution lifecycle.
  """

  @version "0.2.0"
  @spectre_stack_dsl Module.concat(["Spectre", "Stack", "DSL"])
  @spectre_extension Module.concat(["Spectre", "Extension"])

  @doc false
  def manifest do
    [
      id: :kinetic,
      module: __MODULE__,
      version: @version,
      contract: 1,
      provides: [{:service, :kinetic}],
      agent_extensions: [Spectre.Kinetic.Extension],
      dsl: __MODULE__,
      metadata: %{role: :decision_interpreter}
    ]
  end

  @type classifier_config :: %{
          required(:module) => module(),
          required(:options) => keyword()
        }

  @type stack_config :: %{
          required(:options) => keyword(),
          required(:classifiers) => [classifier_config()]
        }

  @doc false
  @spec compile(keyword(), Macro.t() | nil, Macro.Env.t()) :: {:ok, stack_config()}
  def compile(opts, block, caller) do
    classifiers =
      apply(@spectre_stack_dsl, :compile!, [block, caller, [classifier: [1, 2]]])
      |> Enum.map(&classifier_config!/1)

    {:ok, %{options: opts, classifiers: classifiers}}
  end

  defmacro __using__(opts) do
    quote do
      Spectre.Extension.register!(
        __MODULE__,
        Spectre.Kinetic.Extension,
        unquote(opts)
      )
    end
  end

  @doc """
  Returns the immutable Kinetic configuration bound to an Agent.
  """
  @spec config(module()) :: {:ok, keyword()} | {:error, term()}
  def config(agent) when is_atom(agent) do
    with :ok <- ensure_spectre_extension(),
         {:ok, mount} <- apply(@spectre_extension, :fetch, [agent, :kinetic]),
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
