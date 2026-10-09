defmodule Mayfly.Plug.TestRouter do
  @moduledoc false
  use Plug.Router

  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: JSON)
  plug(:match)
  plug(:dispatch)

  get "/items/:id" do
    ctx = conn.assigns[:lambda_context]

    send_resp(
      conn,
      200,
      JSON.encode!(%{id: id, query: conn.query_params, request_id: ctx && ctx.request_id})
    )
  end

  post "/form" do
    conn
    |> put_resp_header("x-echo", "yes")
    |> send_resp(201, "hello #{conn.body_params["name"]}")
  end

  post "/items/:id" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(conn.body_params))
  end

  get "/cookie" do
    conn
    |> put_resp_cookie("sid", "s1", http_only: true)
    |> put_resp_cookie("theme", "light")
    |> send_resp(204, "")
  end

  get "/png" do
    conn |> put_resp_content_type("image/png") |> send_resp(200, <<137, 80, 78, 71, 0, 0>>)
  end

  get "/file" do
    conn |> put_resp_content_type("text/plain") |> send_file(200, __ENV__.file)
  end

  get "/chunked" do
    conn = conn |> put_resp_content_type("text/plain") |> send_chunked(200)

    Enum.reduce(1..3, conn, fn i, c ->
      {:ok, c} = chunk(c, "part#{i};")
      c
    end)
  end

  get "/boom" do
    _ = conn
    raise ArgumentError, "kaboom"
  end

  get "/chunked-boom" do
    conn = conn |> send_chunked(200)
    {:ok, conn} = chunk(conn, "start;")
    _ = conn
    raise "mid-stream"
  end

  get "/no-response" do
    conn
  end

  match _ do
    send_resp(conn, 404, "nope")
  end
end

defmodule Mayfly.Plug.ErrorHandlerRouter do
  @moduledoc false
  use Plug.Router
  use Plug.ErrorHandler

  plug(:match)
  plug(:dispatch)

  get "/boom" do
    _ = conn
    raise ArgumentError, "kaboom"
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: reason}) do
    send_resp(conn, conn.status, "rendered: #{Exception.message(reason)}")
  end
end

defmodule Mayfly.Plug.TestHandler do
  @moduledoc false
  use Mayfly.Plug.Handler, plug: Mayfly.Plug.TestRouter
end

defmodule Mayfly.Plug.StreamingHandler do
  @moduledoc false
  use Mayfly.Plug.Handler, plug: Mayfly.Plug.TestRouter, streaming: true
end

defmodule Mayfly.Plug.ErrorHandlerHandler do
  @moduledoc false
  use Mayfly.Plug.Handler, plug: Mayfly.Plug.ErrorHandlerRouter
end

defmodule Mayfly.Plug.PropagateHandler do
  @moduledoc false
  use Mayfly.Plug.Handler, plug: Mayfly.Plug.ErrorHandlerRouter, on_error: :propagate
end
