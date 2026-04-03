defmodule SpectreKinetic.Planner.Registry do
  @moduledoc """
  Planner-facing registry behavior plus shared action normalization helpers.

  The planner depends on this behavior instead of directly depending on ETS so
  alternate backends can provide the same registry operations.
  """

  @type action :: map()
  @type embedding_matrix :: {Nx.Tensor.t(), [binary()]}

  @callback new(keyword()) :: {:ok, term()} | {:error, term()}
  @callback load_json(term(), binary()) :: {:ok, term()} | {:error, term()}
  @callback load_compiled(term(), binary()) :: {:ok, term()} | {:error, term()}
  @callback all_actions(term()) :: [action()]
  @callback get_action(term(), binary()) :: action() | nil
  @callback action_count(term()) :: non_neg_integer()
  @callback add_action(term(), map()) :: {:ok, term()} | {:error, term()}
  @callback delete_action(term(), binary()) :: {{:ok, boolean()}, term()} | {:error, term()}
  @callback embedding_matrix(term()) :: embedding_matrix() | nil
  @callback put_embedding(term(), binary(), Nx.Tensor.t()) :: {:ok, term()} | {:error, term()}
  @callback tool_cards(term()) :: [{binary(), binary()}]
  @callback resolve_alias(term(), binary()) :: [{binary(), binary()}]
  @callback close(term()) :: :ok

  @doc """
  Normalizes one raw registry action into the planner's canonical action shape.
  """
  @spec normalize_action(map()) :: {:ok, action()} | {:error, term()}
  def normalize_action(raw) when is_map(raw) do
    raw = stringify_map(raw)
    id = raw["id"] || build_action_id(raw)

    case id do
      nil ->
        {:error, :missing_id}

      _ ->
        {:ok,
         %{
           "id" => id,
           "module" => raw["module"],
           "name" => raw["name"],
           "arity" => raw["arity"],
           "doc" => raw["doc"] || "",
           "spec" => raw["spec"] || "",
           "args" => normalize_args(raw["args"] || []),
           "examples" => raw["examples"] || []
         }}
    end
  end

  def normalize_action(_raw), do: {:error, :invalid_action}

  @doc """
  Builds a compact retrieval card from one normalized action definition.
  """
  @spec build_tool_card(action()) :: binary()
  def build_tool_card(action) do
    name_part = action["name"] || ""
    module_part = action["module"] || ""
    doc_part = action["doc"] || ""

    arg_names =
      action["args"]
      |> List.wrap()
      |> Enum.map(& &1["name"])
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    examples =
      action["examples"]
      |> List.wrap()
      |> Enum.take(3)
      |> Enum.join(" | ")

    [
      "#{module_part}.#{name_part}",
      doc_part,
      if(arg_names != "", do: "args: #{arg_names}"),
      if(examples != "", do: "examples: #{examples}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" - ")
  end

  defp build_action_id(%{"module" => mod, "name" => name, "arity" => arity})
       when is_binary(mod) and is_binary(name) and is_integer(arity) do
    "#{mod}.#{name}/#{arity}"
  end

  defp build_action_id(_raw), do: nil

  defp normalize_args(args) when is_list(args) do
    Enum.map(args, fn arg ->
      arg = stringify_map(arg)

      %{
        "name" => arg["name"] || "",
        "type" => arg["type"] || "String.t()",
        "required" => Map.get(arg, "required", true),
        "aliases" => arg["aliases"] || []
      }
    end)
  end

  defp normalize_args(_args), do: []

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} -> {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
