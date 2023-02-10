defmodule Nostrum.Api.Base do
  @moduledoc false

  @version Nostrum.Mixfile.project()[:version]

  import Nostrum.Constants, only: [base_route: 0]

  alias Nostrum.Api.Ratelimiter

  @type methods :: :get | :post | :put | :delete

  @spec request(pid, methods(), String.t(), iodata(), [{String.t(), String.t()}], Enum.t()) ::
          {:error, :timeout | {:connection_error, any} | {:down, any} | {:stream_error, any}}
          | {:ok, {non_neg_integer, [{String.t(), String.t()}], binary}}
  def request(conn, method, route, body, raw_headers, params) do
    headers = process_request_headers(raw_headers)
    # Convert method from atom to string for `:gun`
    method_as_string =
      method
      |> Atom.to_string()
      |> String.upcase()

    query_string = URI.encode_query(params)

    full_route = "#{base_route()}#{route}?#{query_string}"
    headers = process_request_headers(headers, body)
    stream = :gun.request(conn, method_as_string, full_route, headers, process_request_body(body))

    case :gun.await(conn, stream) do
      {:response, :fin, status, headers} ->
        {:ok, {status, headers, ""}}

      {:response, :nofin, status, headers} ->
        {:ok, body} = :gun.await_body(conn, stream)
        {:ok, {status, headers, body}}

      {:error, {:stream_error, :closed}} ->
        # Temporarily spin up a new connection to handle the request
        # Send a message to the Ratelimiter GenServer to spin up a new connection
        # And then close the temporary connection
        new_connection = Ratelimiter.create_connection()
        response = request(new_connection, method, route, body, raw_headers, params)
        Process.send(Ratelimiter, :remove_old_buckets, [:noconnect])
        :ok = Ratelimiter.close_connection(new_connection)
        response

      {:error, _reason} = result ->
        result
    end
  end

  def process_request_headers(headers, ""), do: :proplists.delete("content-type", headers)
  def process_request_headers(headers, _body), do: headers
  def process_request_body(""), do: ""
  def process_request_body({:multipart, content}), do: content
  def process_request_body(body), do: Jason.encode_to_iodata!(body)

  def process_request_headers(headers) do
    user_agent = [
      {"user-agent", "DiscordBot (https://github.com/kraigie/nostrum, #{@version})"} | headers
    ]

    token = "Bot #{Application.get_env(:nostrum, :token)}"

    [{"authorization", token} | user_agent]
  end

  def process_response_body(body) do
    body
  end
end
