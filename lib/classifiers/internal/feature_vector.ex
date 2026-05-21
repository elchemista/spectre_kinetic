defmodule SpectreKinetic.Classifiers.Internal.FeatureVector do
  @moduledoc false

  @doc false
  @spec tensor([number()], pos_integer()) :: {:ok, Nx.Tensor.t()} | {:error, term()}
  def tensor(features, expected_dim) when is_list(features) and is_integer(expected_dim) do
    if length(features) == expected_dim do
      {:ok, Nx.tensor([Enum.map(features, &number/1)], type: :f32)}
    else
      {:error, {:feature_dim_mismatch, expected_dim, length(features)}}
    end
  end

  @doc false
  @spec number(term()) :: float()
  def number(value) when is_integer(value), do: value * 1.0
  def number(value) when is_float(value), do: value
  def number(true), do: 1.0
  def number(false), do: 0.0
  def number(nil), do: 0.0

  def number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> 0.0
    end
  end

  def number(_value), do: 0.0

  @doc false
  @spec presence(term()) :: float()
  def presence(nil), do: 0.0
  def presence(""), do: 0.0
  def presence([]), do: 0.0
  def presence(%{} = map) when map_size(map) == 0, do: 0.0
  def presence(_value), do: 1.0

  @doc false
  @spec clamp(number(), number(), number()) :: float()
  def clamp(value, min, _max) when value < min, do: min * 1.0
  def clamp(value, _min, max) when value > max, do: max * 1.0
  def clamp(value, _min, _max), do: value * 1.0

  @doc false
  @spec ratio(number(), pos_integer() | number()) :: float()
  def ratio(_value, 0), do: 0.0
  def ratio(value, max), do: value |> number() |> Kernel./(max) |> clamp(0.0, 1.0)

  @doc false
  @spec bool(boolean()) :: float()
  def bool(true), do: 1.0
  def bool(false), do: 0.0

  @doc false
  @spec status(atom()) :: float()
  def status(:ok), do: 1.0
  def status(:needs_confirmation), do: 0.6
  def status(:needs_clarification), do: 0.3
  def status(_status), do: 0.0
end
