defmodule SpectreKinetic.ClassifierPipeline do
  @moduledoc """
  Phoenix Plug-style executor for planning-time classifiers.
  """

  alias SpectreKinetic.PlanContext

  defmodule Spec do
    @moduledoc false

    defstruct [:module, :state]

    @type t :: %__MODULE__{module: module(), state: term()}
  end

  @type classifier_spec :: module() | {module(), keyword()} | Spec.t()

  @doc """
  Initializes classifier specs once for runtime/configured pipelines.
  """
  @spec init_specs([module() | {module(), keyword()}]) ::
          {:ok, [Spec.t()]} | {:error, {module(), term()} | term()}
  def init_specs(classifier_specs) when is_list(classifier_specs) do
    Enum.reduce_while(classifier_specs, {:ok, []}, fn spec, {:ok, acc} ->
      with {:ok, {module, opts}} <- normalize_declaration(spec),
           {:ok, state} <- init_classifier(module, opts) do
        {:cont, {:ok, [%Spec{module: module, state: state} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Runs classifier specs in order.

  `{:ok, context}` continues, `{:halt, context}` stops successfully and marks
  the context as halted, and `{:error, reason}` stops with the classifier module
  attached to the error.
  """
  @spec run(PlanContext.t(), [classifier_spec()]) ::
          {:ok, PlanContext.t()} | {:error, {module(), term()} | term()}
  def run(%PlanContext{} = context, classifier_specs) when is_list(classifier_specs) do
    Enum.reduce_while(classifier_specs, {:ok, context}, fn spec, {:ok, context} ->
      case normalize_spec(spec) do
        {:ok, {module, state}} ->
          run_classifier(module, state, context)

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_spec(%Spec{module: module, state: state}) when is_atom(module),
    do: {:ok, {module, state}}

  defp normalize_spec(spec) do
    with {:ok, {module, opts}} <- normalize_declaration(spec),
         {:ok, state} <- init_classifier(module, opts) do
      {:ok, {module, state}}
    end
  end

  defp normalize_declaration(module) when is_atom(module), do: {:ok, {module, []}}

  defp normalize_declaration({module, opts}) when is_atom(module) and is_list(opts),
    do: {:ok, {module, opts}}

  defp normalize_declaration(spec), do: {:error, {:invalid_classifier_spec, spec}}

  defp init_classifier(module, opts) do
    {:ok, module.init(opts)}
  rescue
    error -> {:error, {module, error}}
  end

  defp run_classifier(module, state, context) do
    case module.call(context, state) do
      {:ok, %PlanContext{} = new_context} ->
        {:cont, {:ok, new_context}}

      {:halt, %PlanContext{} = halted_context} ->
        {:halt, {:ok, %{halted_context | halted?: true}}}

      {:error, reason} ->
        {:halt, {:error, {module, reason}}}

      other ->
        {:halt, {:error, {module, {:invalid_classifier_return, other}}}}
    end
  rescue
    error -> {:halt, {:error, {module, error}}}
  end
end
