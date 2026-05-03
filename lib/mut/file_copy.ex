defmodule Mut.FileCopy do
  @moduledoc "Copies directories using copy-on-write when available."

  @spec copy_tree(Path.t(), Path.t()) :: :ok | {:error, term}
  def copy_tree(source, destination) do
    case cow_copy(source, destination) do
      :ok -> :ok
      {:error, _reason} -> plain_copy(source, destination)
    end
  end

  @spec cow_copy(Path.t(), Path.t()) :: :ok | {:error, term}
  def cow_copy(source, destination) do
    case :os.type() do
      {:unix, :darwin} -> run_cp(["-Rc", source, destination])
      {:unix, :linux} -> run_cp(["-R", "--reflink=auto", source, destination])
      _other -> {:error, :unsupported_platform}
    end
  end

  @spec plain_copy(Path.t(), Path.t()) :: :ok | {:error, term}
  def plain_copy(source, destination) do
    File.cp_r!(source, destination)
    :ok
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp run_cp(args) do
    case System.cmd("cp", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, {:cp_failed, exit_code, output}}
    end
  end
end
