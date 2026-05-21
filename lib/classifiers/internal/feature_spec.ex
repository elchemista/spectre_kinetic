defmodule SpectreKinetic.Classifiers.Internal.FeatureSpec do
  @moduledoc false

  @doc false
  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__), only: [feature: 2]

      Module.register_attribute(__MODULE__, :feature_specs, accumulate: true)
      @before_compile unquote(__MODULE__)
    end
  end

  @doc false
  defmacro feature(name, function_name) when is_atom(name) and is_atom(function_name) do
    quote bind_quoted: [name: name, function_name: function_name] do
      @feature_specs {name, function_name}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    specs =
      env.module
      |> Module.get_attribute(:feature_specs)
      |> Enum.reverse()

    names = Enum.map(specs, fn {name, _function_name} -> name end)

    values =
      Enum.map(specs, fn {_name, function_name} ->
        quote do
          unquote(function_name)(features)
        end
      end)

    quote do
      @feature_names unquote(names)

      @doc """
      Returns feature names in vector order.
      """
      @spec feature_names() :: [atom()]
      def feature_names, do: @feature_names

      @doc """
      Returns the number of numeric features emitted by this builder.
      """
      @spec dim() :: pos_integer()
      def dim, do: length(@feature_names)

      @spec feature_values(term()) :: [float()]
      defp feature_values(features), do: [unquote_splicing(values)]
    end
  end
end
