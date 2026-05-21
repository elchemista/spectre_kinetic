defmodule SpectreKinetic.Classifiers.SlotConfidence.Features do
  @moduledoc """
  Stable 10-dimensional feature vector for one mapped slot.
  """

  alias SpectreKinetic.Classifiers.Internal.FeatureVector
  alias SpectreKinetic.PlanContext
  alias SpectreKinetic.Planner.SlotMapper

  use SpectreKinetic.Classifiers.Internal.FeatureSpec

  feature(:value_presence, :value_presence_feature)
  feature(:missing_slot, :missing_slot_feature)
  feature(:exact_source, :exact_source_feature)
  feature(:alias_source, :alias_source_feature)
  feature(:type_shape_match, :type_shape_match_feature)
  feature(:required_slot, :required_slot_feature)
  feature(:value_length, :value_length_feature)
  feature(:mapped_arg_count, :mapped_arg_count_feature)
  feature(:parsed_arg_count, :parsed_arg_count_feature)
  feature(:missing_count, :missing_count_feature)

  @typep slot_features :: %{
           required(:arg_def) => map(),
           required(:args) => map(),
           required(:missing) => [binary()],
           required(:name) => binary(),
           required(:normalized_name) => binary(),
           required(:parsed_args) => map(),
           required(:source) => binary() | nil,
           required(:value) => term()
         }

  @doc """
  Builds the numeric feature vector for a single mapped slot.
  """
  @spec build(PlanContext.t(), map()) :: [float()]
  def build(%PlanContext{} = context, arg_def) when is_map(arg_def) do
    context
    |> slot_features(arg_def)
    |> feature_values()
  end

  @doc """
  Returns the parsed argument key that matched the slot name or aliases.
  """
  @spec exact_or_alias_source(map(), map()) :: binary() | nil
  def exact_or_alias_source(parsed_args, arg_def) do
    normalized = normalize_keys(parsed_args)
    name = normalized_arg_name(arg_def)
    aliases = normalized_aliases(arg_def)

    Enum.find([name | aliases], &Map.has_key?(normalized, &1))
  end

  @doc """
  Returns true when a mapped value has a shape consistent with the slot definition.
  """
  @spec type_shape_match?(term(), map()) :: boolean()
  def type_shape_match?(value, arg_def) do
    value
    |> SlotMapper.detect_value_type()
    |> type_shape_match?(normalized_arg_name(arg_def), normalized_arg_type(arg_def))
  end

  @spec slot_features(PlanContext.t(), map()) :: slot_features()
  defp slot_features(%PlanContext{} = context, arg_def) do
    name = to_string(arg_def["name"])
    args = PlanContext.args(context)
    parsed_args = PlanContext.parsed_args(context)

    %{
      arg_def: arg_def,
      args: args,
      missing: PlanContext.missing_fields(context),
      name: name,
      normalized_name: String.downcase(name),
      parsed_args: parsed_args,
      source: exact_or_alias_source(parsed_args, arg_def),
      value: Map.get(args, name)
    }
  end

  @spec value_presence_feature(slot_features()) :: float()
  defp value_presence_feature(%{value: value}), do: FeatureVector.presence(value)

  @spec missing_slot_feature(slot_features()) :: float()
  defp missing_slot_feature(%{name: name, missing: missing}) do
    FeatureVector.bool(name in missing)
  end

  @spec exact_source_feature(slot_features()) :: float()
  defp exact_source_feature(%{source: source, normalized_name: name}) do
    FeatureVector.bool(source == name)
  end

  @spec alias_source_feature(slot_features()) :: float()
  defp alias_source_feature(%{source: source, arg_def: arg_def}) do
    FeatureVector.bool(source in normalized_aliases(arg_def))
  end

  @spec type_shape_match_feature(slot_features()) :: float()
  defp type_shape_match_feature(%{value: value, arg_def: arg_def}) do
    FeatureVector.bool(type_shape_match?(value, arg_def))
  end

  @spec required_slot_feature(slot_features()) :: float()
  defp required_slot_feature(%{arg_def: arg_def}) do
    FeatureVector.bool(Map.get(arg_def, "required", true))
  end

  @spec value_length_feature(slot_features()) :: float()
  defp value_length_feature(%{value: value}), do: FeatureVector.ratio(value_length(value), 200)

  @spec mapped_arg_count_feature(slot_features()) :: float()
  defp mapped_arg_count_feature(%{args: args}), do: FeatureVector.ratio(map_size(args), 20)

  @spec parsed_arg_count_feature(slot_features()) :: float()
  defp parsed_arg_count_feature(%{parsed_args: parsed_args}) do
    FeatureVector.ratio(map_size(parsed_args), 20)
  end

  @spec missing_count_feature(slot_features()) :: float()
  defp missing_count_feature(%{missing: missing}), do: FeatureVector.ratio(length(missing), 10)

  @spec type_shape_match?(atom(), binary(), binary()) :: boolean()
  defp type_shape_match?(:email, name, type) do
    name in ~w(to email recipient cc bcc reply_to from sender) or String.contains?(type, "email")
  end

  defp type_shape_match?(:phone, name, _type),
    do: name in ~w(to phone number recipient mobile cell)

  defp type_shape_match?(:url, name, _type), do: name in ~w(url uri link website href endpoint)

  defp type_shape_match?(:date, name, _type),
    do: name in ~w(due date deadline start_date end_date)

  defp type_shape_match?(:path, name, _type),
    do: name in ~w(path file source dest destination target dir directory location)

  defp type_shape_match?(:integer, name, type) do
    String.contains?(type, "integer") or name in ~w(id count limit offset port priority)
  end

  defp type_shape_match?(:float, name, type) do
    String.contains?(type, "float") or name in ~w(amount price rate score threshold confidence)
  end

  defp type_shape_match?(:boolean, name, type) do
    String.contains?(type, "boolean") or
      name in ~w(enabled active force draft published confirmed)
  end

  defp type_shape_match?(_detected, _name, _type), do: false

  @spec normalize_keys(map()) :: map()
  defp normalize_keys(parsed_args) do
    Map.new(parsed_args, fn {key, value} -> {String.downcase(to_string(key)), value} end)
  end

  @spec normalized_arg_name(map()) :: binary()
  defp normalized_arg_name(arg_def),
    do: arg_def |> Map.get("name", "") |> to_string() |> String.downcase()

  @spec normalized_arg_type(map()) :: binary()
  defp normalized_arg_type(arg_def),
    do: arg_def |> Map.get("type", "") |> to_string() |> String.downcase()

  @spec normalized_aliases(map()) :: [binary()]
  defp normalized_aliases(arg_def), do: Enum.map(arg_def["aliases"] || [], &String.downcase/1)

  @spec value_length(term()) :: non_neg_integer()
  defp value_length(value) do
    value
    |> to_string()
    |> String.length()
  end
end
