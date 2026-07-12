defmodule SpectreKinetic.Artifact do
  @moduledoc """
  Size-limited readers for Kinetic runtime artifacts.

  ETF artifacts are decoded with Erlang's `:safe` option so a file cannot create
  new atoms or restore unknown runtime-specific terms. Callers remain
  responsible for validating the decoded artifact schema before activating it.
  """

  @default_term_max_bytes 256 * 1_024 * 1_024
  @default_json_max_bytes 4 * 1_024 * 1_024

  @type decode_error ::
          {:artifact_too_large, Path.t() | :binary, non_neg_integer(), pos_integer()}
          | {:artifact_expands_too_large, Path.t() | :binary, non_neg_integer(), pos_integer()}
          | {:invalid_artifact_term, Exception.t()}
          | {:invalid_artifact_json, term()}
          | File.posix()

  @doc "Reads and safely decodes one ETF artifact."
  @spec read_term(Path.t(), keyword()) :: {:ok, term()} | {:error, decode_error()}
  def read_term(path, opts \\ []) when is_binary(path) and is_list(opts) do
    max_bytes = max_bytes(opts, :max_bytes, @default_term_max_bytes)
    max_decoded_bytes = max_bytes(opts, :max_decoded_bytes, max_bytes)

    with {:ok, binary} <- read_limited(path, max_bytes) do
      decode_term(binary,
        max_bytes: max_bytes,
        max_decoded_bytes: max_decoded_bytes,
        source: path
      )
    end
  end

  @doc "Safely decodes an ETF binary after enforcing a size limit."
  @spec decode_term(binary(), keyword()) :: {:ok, term()} | {:error, decode_error()}
  def decode_term(binary, opts \\ []) when is_binary(binary) and is_list(opts) do
    max_bytes = max_bytes(opts, :max_bytes, @default_term_max_bytes)
    max_decoded_bytes = max_bytes(opts, :max_decoded_bytes, max_bytes)
    source = Keyword.get(opts, :source, :binary)

    with :ok <- validate_size(source, byte_size(binary), max_bytes),
         :ok <- validate_decoded_size(source, binary, max_decoded_bytes) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    end
  rescue
    error in ArgumentError -> {:error, {:invalid_artifact_term, error}}
  end

  @doc "Reads and decodes one size-limited JSON artifact."
  @spec read_json(Path.t(), keyword()) :: {:ok, term()} | {:error, decode_error()}
  def read_json(path, opts \\ []) when is_binary(path) and is_list(opts) do
    max_bytes = max_bytes(opts, :max_bytes, @default_json_max_bytes)

    with {:ok, json} <- read_limited(path, max_bytes) do
      decode_json(json)
    end
  end

  @spec decode_json(binary()) :: {:ok, term()} | {:error, decode_error()}
  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_artifact_json, error}}
    end
  end

  @spec read_limited(Path.t(), pos_integer()) :: {:ok, binary()} | {:error, decode_error()}
  defp read_limited(path, max_bytes) do
    with {:ok, stat} <- File.stat(path),
         :ok <- validate_size(path, stat.size, max_bytes),
         {:ok, device} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(device, max_bytes + 1) do
          :eof -> {:ok, <<>>}
          {:error, reason} -> {:error, reason}
          binary -> limited_binary(path, binary, max_bytes)
        end
      after
        File.close(device)
      end
    end
  end

  @spec limited_binary(Path.t(), binary(), pos_integer()) ::
          {:ok, binary()} | {:error, decode_error()}
  defp limited_binary(_path, binary, max_bytes) when byte_size(binary) <= max_bytes,
    do: {:ok, binary}

  defp limited_binary(path, binary, max_bytes),
    do: {:error, {:artifact_too_large, path, byte_size(binary), max_bytes}}

  @spec validate_size(Path.t(), non_neg_integer(), pos_integer()) ::
          :ok | {:error, decode_error()}
  defp validate_size(_path, size, max_bytes) when size <= max_bytes, do: :ok

  defp validate_size(path, size, max_bytes),
    do: {:error, {:artifact_too_large, path, size, max_bytes}}

  @spec validate_decoded_size(Path.t() | :binary, binary(), pos_integer()) ::
          :ok | {:error, decode_error()}
  defp validate_decoded_size(source, binary, max_decoded_bytes) do
    decoded_size = declared_decoded_size(binary)

    if decoded_size <= max_decoded_bytes do
      :ok
    else
      {:error,
       {:artifact_expands_too_large, source, decoded_size, max_decoded_bytes}}
    end
  end

  # COMPRESSED_EXT includes the exact uncompressed external-term size before
  # the zlib stream. Reject it before asking the VM to allocate/decompress it.
  @spec declared_decoded_size(binary()) :: non_neg_integer()
  defp declared_decoded_size(<<131, 80, size::unsigned-big-integer-size(32), _rest::binary>>),
    do: size

  defp declared_decoded_size(binary), do: byte_size(binary)

  @spec max_bytes(keyword(), atom(), pos_integer()) :: pos_integer()
  defp max_bytes(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end
end
