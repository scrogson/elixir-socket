#            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#                    Version 2, December 2004
#
#            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION
#
#  0. You just DO WHAT THE FUCK YOU WANT TO.

defprotocol Socket.Stream.Protocol do
  @doc """
  Send data through the socket.
  """
  @spec send(t, iodata) :: :ok | { :error, term }
  def send(self, data)

  @doc """
  Send a file through the socket, using non-copying operations where available.
  """
  @spec file(t, String.t)            :: :ok | { :error, term }
  @spec file(t, String.t, Keyword.t) :: :ok | { :error, term }
  def file(self, path, options // [])

  @doc """
  Receive data from the socket compatible with the packet type.
  """
  @spec recv(t) :: { :ok, term } | { :error, term }
  def recv(self)

  @doc """
  Receive data from the socket with the given length or options.
  """
  @spec recv(t, non_neg_integer | Keyword.t) :: { :ok, term } | { :error, term }
  def recv(self, length_or_options)

  @doc """
  Receive data from the socket with the given length and options.
  """
  @spec recv(t, non_neg_integer, Keyword.t) :: { :ok, term } | { :error, term }
  def recv(self, length, options)

  @doc """
  Shutdown the socket in the given mode, either `:both`, `:read`, or `:write`.
  """
  @spec shutdown(t, :both | :read | :write) :: :ok | { :error, term }
  def shutdown(self, how // :both)
end

defmodule Socket.Stream do
  @type t :: Socket.Stream.Protocol.t

  use Socket.Helpers
  import Kernel, except: [send: 2]

  defdelegate send(self, data), to: Socket.Stream.Protocol
  defbang     send(self, data), to: Socket.Stream.Protocol

  defdelegate file(self, path), to: Socket.Stream.Protocol
  defbang     file(self, path), to: Socket.Stream.Protocol
  defdelegate file(self, path, options), to: Socket.Stream.Protocol
  defbang     file(self, path, options), to: Socket.Stream.Protocol

  defdelegate recv(self), to: Socket.Stream.Protocol
  defbang     recv(self), to: Socket.Stream.Protocol
  defdelegate recv(self, length_or_options), to: Socket.Stream.Protocol
  defbang     recv(self, length_or_options), to: Socket.Stream.Protocol
  defdelegate recv(self, length, options), to: Socket.Stream.Protocol
  defbang     recv(self, length, options), to: Socket.Stream.Protocol

  defdelegate shutdown(self), to: Socket.Stream.Protocol
  defbang     shutdown(self), to: Socket.Stream.Protocol
  defdelegate shutdown(self, how), to: Socket.Stream.Protocol
  defbang     shutdown(self, how), to: Socket.Stream.Protocol

  @doc """
  Read from the IO device and send to the socket following the given options.

  ## Options

    - `:size` is the amount of bytes to read from the IO device, if omitted it
      will read until EOF
    - `:offset` is the amount of bytes to read from the IO device before
      starting to send what's being read
    - `:chunk_size` is the size of the chunks read from the IO device at a time

  """
  @spec io(t, :io.device)            :: :ok | { :error, term }
  @spec io(t, :io.device, Keyword.t) :: :ok | { :error, term }
  def io(self, io, options // []) do
    if offset = options[:offset] do
      case IO.binread(io, offset) do
        :eof ->
          :ok

        { :error, _ } = error ->
          error

        _ ->
          io(0, self, io, options[:size] || -1, options[:chunk_size] || 4096)
      end
    else
      io(0, self, io, options[:size] || -1, options[:chunk_size] || 4096)
    end
  end

  defp io(total, self, io, size, chunk_size) when size > 0 and total + chunk_size > size do
    case IO.binread(io, size - total) do
      :eof ->
        :ok

      { :error, _ } = error ->
        error

      data ->
        self |> send(data)
    end
  end

  defp io(total, self, io, size, chunk_size) do
    case IO.binread(io, chunk_size) do
      :eof ->
        :ok

      { :error, _ } = error ->
        error

      data ->
        self |> send(data)

        io(total + chunk_size, self, io, size, chunk_size)
    end
  end

  defbang io(self, io)
  defbang io(self, io, options)
end

defimpl Socket.Stream.Protocol, for: Port do
  def send(self, data) do
    :gen_tcp.send(self, data)
  end

  def file(self, path, options // []) do
    cond do
      options[:size] && options[:chunk_size] ->
        :file.sendfile(path, self, options[:offset] || 0, options[:size], chunk_size: options[:chunk_size])

      options[:size] ->
        :file.sendfile(path, self, options[:offset] || 0, options[:size], [])

      true ->
        :file.sendfile(path, self)
    end
  end

  def recv(self) do
    recv(self, 0, [])
  end

  def recv(self, length) when is_integer(length) do
    recv(self, length, [])
  end

  def recv(self, options) when is_list(options) do
    recv(self, 0, options)
  end

  def recv(self, length, options) do
    case :gen_tcp.recv(self, length, options[:timeout] || :infinity) do
      { :ok, _ } = ok ->
        ok

      { :error, :closed } ->
        { :ok, nil }

      { :error, _ } = error ->
        error
    end
  end

  def shutdown(self, how // :both) do
    :gen_tcp.shutdown(self, case how do
      :read  -> :read
      :write -> :write
      :both  -> :read_write
    end)
  end
end

defimpl Socket.Stream.Protocol, for: Tuple do
  def send(self, data) when self |> is_record :sslsocket do
    :ssl.send(self, data)
  end

  def file(self, path, options // []) when self |> is_record :sslsocket do
    cond do
      options[:size] && options[:chunk_size] ->
        file(self, path, options[:offset] || 0, options[:size], options[:chunk_size])

      options[:size] ->
        file(self, path, options[:offset] || 0, options[:size], 4096)

      true ->
        file(self, path, 0, -1, 4096)
    end
  end

  defp file(self, path, offset, -1, chunk_size) when path |> is_binary do
    file(self, path, offset, File.stat!(path).size, chunk_size)
  end

  defp file(self, path, offset, size, chunk_size) when path |> is_binary do
    case File.open!(path, [:read], &Socket.Stream.io(self, &1, offset: offset, size: size, chunk_size: chunk_size)) do
      { :ok, :ok } ->
        :ok

      { :ok, { :error, _ } = error } ->
        error

      { :error, _ } = error ->
        error
    end
  end

  def recv(self) when self |> is_record :sslsocket do
    recv(self, 0, [])
  end

  def recv(self, length) when self |> is_record :sslsocket and is_integer(length) do
    recv(self, length, [])
  end

  def recv(self, options) when self |> is_record :sslsocket and is_list(options) do
    recv(self, 0, options)
  end

  def recv(self, length, options) when self |> is_record :sslsocket do
    case :ssl.recv(self, length, options[:timeout] || :infinity) do
      { :ok, _ } = ok ->
        ok

      { :error, :closed } ->
        { :ok, nil }

      { :error, _ } = error ->
        error
    end
  end

  def shutdown(self, how // :both) do
    :ssl.shutdown(self, case how do
      :read  -> :read
      :write -> :write
      :both  -> :read_write
    end)
  end
end
