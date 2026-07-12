defmodule SpectreKinetic.ClassifierPipeline do
  @moduledoc """
  Phoenix Plug-style executor for planning-time classifiers.
  """

  alias SpectreKinetic.PlanContext

  # A classifier may only move a plan toward a more restrictive outcome.
  @status_ranks %{
    ok: 0,
    needs_confirmation: 10,
    needs_clarification: 20,
    ambiguous_mapping: 30,
    missing_args: 40,
    no_tool: 50,
    rejected: 60,
    error: 70
  }

  @known_statuses Map.keys(@status_ranks)

  defmodule Spec do
    @moduledoc false

    defstruct [:module, :state]

    @type t :: %__MODULE__{module: module(), state: term()}
  end

  @type classifier_spec :: module() | {module(), keyword()} | Spec.t()

  @doc """
  Initializes classifier specs once for runtime/configured pipelines.
  """
  @spec init_specs([classifier_spec()]) ::
          {:ok, [Spec.t()]} | {:error, {module(), term()} | term()}
  def init_specs(classifier_specs) when is_list(classifier_specs) do
    classifier_specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case initialize_spec(spec) do
        {:ok, initialized} -> {:cont, {:ok, [initialized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> initialized_specs()
  end

  defp initialize_spec(%Spec{module: module} = spec) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :call, 2) do
      {:ok, spec}
    else
      {:error, {:invalid_classifier_spec, spec}}
    end
  end

  defp initialize_spec(spec) do
    with {:ok, {module, opts}} <- normalize_declaration(spec),
         {:ok, state} <- init_classifier(module, opts) do
      {:ok, %Spec{module: module, state: state}}
    end
  end

  defp initialized_specs({:ok, specs}), do: {:ok, Enum.reverse(specs)}
  defp initialized_specs({:error, _reason} = error), do: error

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
        {:cont, {:ok, reconcile_status(context, new_context)}}

      {:halt, %PlanContext{} = halted_context} ->
        halted_context =
          context
          |> reconcile_status(halted_context)
          |> fail_closed_halt()

        {:halt, {:ok, %{halted_context | halted?: true}}}

      {:error, reason} ->
        {:halt, {:error, {module, reason}}}

      other ->
        {:halt, {:error, {module, {:invalid_classifier_return, other}}}}
    end
  rescue
    error -> {:halt, {:error, {module, error}}}
  end

  defp reconcile_status(previous, next) do
    previous_status = normalize_classifier_status(previous.status)
    next_status = normalize_classifier_status(next.status)

    status =
      if status_rank(next_status) > status_rank(previous_status) do
        next_status
      else
        previous_status
      end

    %{next | status: status}
  end

  defp fail_closed_halt(%PlanContext{status: :ok} = context),
    do: %{context | status: :needs_confirmation}

  defp fail_closed_halt(context), do: context

  defp normalize_classifier_status(status) when status in @known_statuses, do: status
  defp normalize_classifier_status(_status), do: :error

  defp status_rank(status), do: Map.fetch!(@status_ranks, status)
end
