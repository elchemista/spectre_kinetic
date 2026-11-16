defmodule Spectre.Kinetic.ServerTool do
  @moduledoc """
  Stack tool adapter for consolidated model responses in Spectre 0.4.

  The core generates `kinetic/3` from the installation. This adapter only
  prepares candidates; it never executes actions or grants authority.
  """

  @action_config Module.concat(["Spectre", "ActionConfig"])
  @planning Module.concat(["Spectre", "Server", "Planning"])

  if Code.ensure_loaded?(Spectre.Server.GAM.EffectAdapter) do
    @behaviour Spectre.Server.GAM.EffectAdapter
  end

  @doc "Executes only a registered action after GAM admission; never retries."
  @spec execute_effect(atom() | binary(), map(), map()) ::
          {:ok, term()} | {:error, :failed | :definitive_no_effect | :ambiguous, term()}
  def execute_effect(name, args, %{effect_config: config, effect_schema_hash: hash}) do
    action = %{name: name, args: args, schema_hash: hash}

    case Spectre.Kinetic.Actions.validate(action, config.options) do
      :ok -> admitted_result(Spectre.Kinetic.Actions.execute(action, %{}, config.options))
      {:error, reason} -> {:error, :definitive_no_effect, reason}
    end
  end

  @doc "Resolves the loaded action schema after the annotated module has finished compiling."
  @spec effect_schema(atom() | binary(), map()) :: {:ok, binary()} | {:error, term()}
  def effect_schema(name, %{config: config}) do
    case Spectre.Kinetic.Actions.actions(config.options) do
      entries when is_list(entries) ->
        case Enum.find(entries, &(&1.name == name)) do
          nil ->
            {:error, :registered_action_unavailable}

          spec ->
            spec_module = Module.concat(["Spectre", "Action", "Spec"])

            normalized =
              apply(spec_module, :new, [Map.put(spec, :via, config.options[:provider_id])])

            {:ok, normalized.schema_hash}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec admitted_result(term()) ::
          {:ok, term()} | {:error, :failed | :definitive_no_effect | :ambiguous, term()}
  defp admitted_result({:ok, receipt}), do: {:ok, receipt}
  defp admitted_result(:ok), do: {:ok, %{completed: true}}

  defp admitted_result({:error, status, reason})
       when status in [:failed, :definitive_no_effect, :ambiguous],
       do: {:error, status, reason}

  defp admitted_result({:error, reason}), do: {:error, :ambiguous, reason}
  defp admitted_result(_), do: {:error, :ambiguous, :invalid_action_result}

  def prepare(:interpret, [response], trusted), do: prepare(:interpret, response, trusted)

  def prepare(:interpret, %{planning: true}, _trusted),
    do: {:error, :response_already_planned}

  def prepare(:interpret, %{planning: false, model_output: text}, %{agent: agent})
      when is_binary(text) do
    case apply(@action_config, :planner, [agent]) do
      {Spectre.Kinetic.Planner, _opts} -> {:ok, %{text: text}}
      _other -> {:error, :kinetic_planner_required}
    end
  end

  def prepare(:interpret, _response, _trusted), do: {:error, :model_output_required}
  def prepare(_operation, _payload, _trusted), do: {:error, :unknown_kinetic_operation}

  def invoke(:interpret, %{text: text}, %{service_context: context}) do
    apply(@planning, :prepare, [text, context])
  end

  def project(:interpret, {:ok, %{actions: actions, text: text} = result})
      when is_list(actions) and is_binary(text),
      do: {:ok, {:prepared, Map.take(result, [:actions, :text])}}

  def project(:interpret, {:error, reason}), do: {:ok, {:error, reason}}
  def project(_operation, _result), do: {:error, :invalid_kinetic_result}
end
