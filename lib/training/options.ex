defmodule SpectreKinetic.Training.Options do
  @moduledoc false

  @type values :: %{
          hidden_dim: pos_integer(),
          batch_size: pos_integer(),
          epochs: pos_integer(),
          learning_rate: float(),
          seed: non_neg_integer() | nil
        }

  @spec validate(keyword(), keyword()) :: {:ok, values()} | {:error, term()}
  def validate(opts, defaults) when is_list(opts) and is_list(defaults) do
    with {:ok, hidden_dim} <- positive_integer(opts, defaults, :hidden_dim),
         {:ok, batch_size} <- positive_integer(opts, defaults, :batch_size),
         {:ok, epochs} <- positive_integer(opts, defaults, :epochs),
         {:ok, learning_rate} <- positive_number(opts, defaults, :learning_rate),
         {:ok, seed} <- optional_non_negative_integer(opts, :seed) do
      {:ok,
       %{
         hidden_dim: hidden_dim,
         batch_size: batch_size,
         epochs: epochs,
         learning_rate: learning_rate * 1.0,
         seed: seed
       }}
    end
  end

  @spec validate_path(term(), atom()) :: :ok | {:error, term()}
  def validate_path(path, key) when is_binary(path) do
    if String.trim(path) == "" do
      {:error, {:invalid_training_option, key, path}}
    else
      :ok
    end
  end

  def validate_path(path, key), do: {:error, {:invalid_training_option, key, path}}

  defp positive_integer(opts, defaults, key) do
    case Keyword.get(opts, key, Keyword.fetch!(defaults, key)) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_training_option, key, value}}
    end
  end

  defp positive_number(opts, defaults, key) do
    case Keyword.get(opts, key, Keyword.fetch!(defaults, key)) do
      value when is_number(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_training_option, key, value}}
    end
  end

  defp optional_non_negative_integer(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, {:invalid_training_option, key, value}}
    end
  end
end
