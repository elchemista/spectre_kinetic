defmodule Mix.Tasks.Spectre.DownloadEncoder do
  use Mix.Task

  @moduledoc """
  Downloads and exports a Hugging Face encoder model to ONNX format.

  This task downloads the model files needed for the Elixir-native planner:
  `model.onnx`, `tokenizer.json`, and `config.json`.

  ## Usage

      mix spectre.download_encoder --model BAAI/bge-small-en-v1.5 --out artifacts/encoder

  ## Options

    * `--model` — Hugging Face model ID (default `BAAI/bge-small-en-v1.5`)
    * `--out` — output directory (required)
    * `--force` — overwrite existing files
  """

  @shortdoc "Download an ONNX encoder model from Hugging Face"

  @default_model "BAAI/bge-small-en-v1.5"

  @switches [model: :string, out: :string, force: :boolean]

  @impl true
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    model_id = opts[:model] || @default_model
    out_dir = opts[:out] || Mix.raise("missing required option --out")
    force? = opts[:force] || false

    files = ["model.onnx", "tokenizer.json", "config.json"]

    File.mkdir_p!(out_dir)

    Enum.each(files, fn file ->
      dest = Path.join(out_dir, file)

      if File.exists?(dest) && !force? do
        Mix.shell().info("skip #{dest} (exists)")
      else
        url = hf_url(model_id, file)
        Mix.shell().info("downloading #{url}")
        download!(url, dest)
        Mix.shell().info("saved #{dest}")
      end
    end)

    Mix.shell().info("Encoder model ready at #{out_dir}")
  end

  defp hf_url(model_id, file) do
    # For ONNX files, try the onnx/ subfolder on HF if the model has one
    base = "https://huggingface.co/#{model_id}/resolve/main"

    case file do
      "model.onnx" -> "#{base}/onnx/model.onnx"
      other -> "#{base}/#{other}"
    end
  end

  defp download!(url, dest) do
    cond do
      curl = System.find_executable("curl") ->
        {output, status} =
          System.cmd(curl, ["-fsSL", "--retry", "3", url, "-o", dest],
            stderr_to_stdout: true
          )

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
