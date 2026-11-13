defmodule Spectre.Kinetic.ServerTool do
  @moduledoc """
  Stack tool adapter for consolidated model responses in Spectre 0.4.

  The core generates `kinetic/3` from the installation. This adapter only
  prepares candidates; it never executes actions or grants authority.
  """

  @action_config Module.concat(["Spectre", "ActionConfig"])
  @planning Module.concat(["Spectre", "Server", "Planning"])

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
