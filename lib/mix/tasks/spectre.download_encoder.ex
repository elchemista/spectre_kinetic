defmodule Mix.Tasks.Spectre.DownloadEncoder do
  use Mix.Task

  @moduledoc """
  Downloads and exports a Hugging Face encoder model to ONNX format.

  This task downloads the model files needed for the Elixir-native planner:
  `model.onnx`, `tokenizer.json`, and `config.json`.

  ## Usage

      mix spectre.download_encoder \\
        --model BAAI/bge-small-en-v1.5 \\
        --revision 5c38ec7c405ec4b44b94cc5a9bb96e735b38267a \\
        --out artifacts/encoder

  ## Options

    * `--model` — Hugging Face model ID (default `BAAI/bge-small-en-v1.5`)
    * `--revision` — immutable 40-character Hugging Face commit SHA. It may be
      omitted only for the default model, which uses the pin shown above.
    * `--out` — output directory (required)
    * `--force` — overwrite existing files
  """

  @shortdoc "Download an ONNX encoder model from Hugging Face"

  @default_model "BAAI/bge-small-en-v1.5"
  @default_revision "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
  @revision_pattern ~r/\A[0-9a-fA-F]{40}\z/
  @model_segment_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @switches [model: :string, revision: :string, out: :string, force: :boolean]

  @impl Mix.Task
  def run(argv) do
    opts = options!(argv)
    model_id = Keyword.fetch!(opts, :model)
    revision = Keyword.fetch!(opts, :revision)
    out_dir = Keyword.fetch!(opts, :out)
    force? = Keyword.fetch!(opts, :force)

    files = ["model.onnx", "tokenizer.json", "config.json"]

    File.mkdir_p!(out_dir)

    Enum.each(files, fn file ->
      dest = Path.join(out_dir, file)

      if File.exists?(dest) && !force? do
        Mix.shell().info("skip #{dest} (exists)")
      else
        url = hf_url(model_id, revision, file)
        Mix.shell().info("downloading #{url}")
        download!(url, dest)
        Mix.shell().info("saved #{dest}")
      end
    end)

    Mix.shell().info("Encoder model ready at #{out_dir}")
  end

  @doc false
  @spec options!([binary()]) :: keyword()
  def options!(argv) when is_list(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    if args != [], do: Mix.raise("unexpected arguments: #{inspect(args)}")

    model_id = validate_model_id!(opts[:model] || @default_model)
    revision = revision!(model_id, opts[:revision])
    out_dir = validate_out_dir!(opts[:out])

    [model: model_id, revision: revision, out: out_dir, force: opts[:force] || false]
  end

  @doc false
  @spec hf_url(binary(), binary(), binary()) :: binary()
  def hf_url(model_id, revision, file) do
    model_id = validate_model_id!(model_id)
    revision = validate_revision!(revision)

    # For ONNX files, try the onnx/ subfolder on HF if the model has one
    base = "https://huggingface.co/#{model_id}/resolve/#{revision}"

    case file do
      "model.onnx" -> "#{base}/onnx/model.onnx"
      other when other in ["tokenizer.json", "config.json"] -> "#{base}/#{other}"
      other -> Mix.raise("unsupported encoder file: #{inspect(other)}")
    end
  end

  @spec revision!(binary(), binary() | nil) :: binary()
  defp revision!(@default_model, nil), do: @default_revision

  defp revision!(_model_id, nil) do
    Mix.raise("missing required option --revision for a custom --model")
  end

  defp revision!(_model_id, revision), do: validate_revision!(revision)

  @spec validate_revision!(term()) :: binary()
  defp validate_revision!(revision) when is_binary(revision) do
    if Regex.match?(@revision_pattern, revision) do
      String.downcase(revision)
    else
      invalid_revision!()
    end
  end

  defp validate_revision!(_revision), do: invalid_revision!()

  @spec invalid_revision!() :: no_return()
  defp invalid_revision! do
    Mix.raise("--revision must be an immutable 40-character hexadecimal commit SHA")
  end

  @spec validate_model_id!(term()) :: binary()
  defp validate_model_id!(model_id) when is_binary(model_id) do
    segments = String.split(model_id, "/", trim: false)

    valid? =
      byte_size(model_id) in 1..192 and length(segments) in [1, 2] and
        Enum.all?(segments, &Regex.match?(@model_segment_pattern, &1))

    if valid?, do: model_id, else: invalid_model_id!(model_id)
  end

  defp validate_model_id!(model_id), do: invalid_model_id!(model_id)

  @spec invalid_model_id!(term()) :: no_return()
  defp invalid_model_id!(model_id) do
    Mix.raise("invalid Hugging Face model ID: #{inspect(model_id)}")
  end

  @spec validate_out_dir!(term()) :: binary()
  defp validate_out_dir!(out_dir) when is_binary(out_dir) do
    if String.trim(out_dir) != "" and not String.contains?(out_dir, <<0>>) do
      out_dir
    else
      Mix.raise("--out must be a non-empty filesystem path")
    end
  end

  defp validate_out_dir!(nil), do: Mix.raise("missing required option --out")
  defp validate_out_dir!(_out_dir), do: Mix.raise("--out must be a non-empty filesystem path")

  defp download!(url, dest) do
    cond do
      curl = System.find_executable("curl") ->
        {output, status} =
          System.cmd(curl, ["-fsSL", "--retry", "3", url, "-o", dest], stderr_to_stdout: true)

        if status != 0 do
          Mix.raise("download failed (curl): #{output}")
        end

      wget = System.find_executable("wget") ->
        {output, status} =
          System.cmd(wget, ["-q", "-O", dest, url], stderr_to_stdout: true)

        if status != 0 do
          Mix.raise("download failed (wget): #{output}")
        end

      true ->
        Mix.raise("need `curl` or `wget` to download model files")
    end
  end
end
