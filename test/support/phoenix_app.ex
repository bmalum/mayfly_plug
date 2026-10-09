# A minimal Phoenix 1.8 JSON API used only in tests, mirroring what
# `mix phx.new --no-html --no-assets --no-ecto --no-live` generates.
defmodule Mayfly.Plug.PhoenixApp.ErrorJSON do
  @moduledoc false
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end

defmodule Mayfly.Plug.PhoenixApp.HelloController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn

  def index(conn, params) do
    ctx = conn.assigns[:lambda_context]

    json(conn, %{
      hello: params["name"] || "world",
      request_id: ctx && ctx.request_id,
      session_counter: get_session(conn, :counter)
    })
  end

  def create(conn, params) do
    conn |> put_status(201) |> put_resp_header("x-created", "1") |> json(%{received: params})
  end

  def count(conn, _params) do
    n = (get_session(conn, :counter) || 0) + 1
    conn |> put_session(:counter, n) |> json(%{counter: n})
  end

  def stream(conn, _params) do
    conn = conn |> put_resp_content_type("text/plain") |> send_chunked(200)

    Enum.reduce(1..3, conn, fn i, c ->
      {:ok, c} = chunk(c, "tick #{i}\n")
      c
    end)
  end

  def boom(_conn, _params), do: raise("phoenix failure")

  def not_found(_conn, _params),
    do:
      raise(Phoenix.Router.NoRouteError,
        conn: %Plug.Conn{},
        router: Mayfly.Plug.PhoenixApp.Router
      )
end

defmodule Mayfly.Plug.PhoenixApp.Router do
  @moduledoc false
  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
    plug(:fetch_session)
  end

  scope "/api", Mayfly.Plug.PhoenixApp do
    pipe_through(:api)
    get("/hello", HelloController, :index)
    post("/items", HelloController, :create)
    get("/count", HelloController, :count)
    get("/stream", HelloController, :stream)
    get("/boom", HelloController, :boom)
  end
end

defmodule Mayfly.Plug.PhoenixApp.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :mayfly_plug

  @session_options [
    store: :cookie,
    key: "_mayfly_plug_test",
    signing_salt: "testsalt",
    same_site: "Lax"
  ]

  plug(Plug.RequestId)
  plug(Plug.Parsers, parsers: [:urlencoded, :multipart, :json], pass: ["*/*"], json_decoder: JSON)
  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(Mayfly.Plug.PhoenixApp.Router)
end

defmodule Mayfly.Plug.PhoenixHandler do
  @moduledoc false
  use Mayfly.Plug.Handler, plug: {Mayfly.Plug.PhoenixApp.Endpoint, []}
end

defmodule Mayfly.Plug.PhoenixStreamingHandler do
  @moduledoc false
  use Mayfly.Plug.Handler, plug: {Mayfly.Plug.PhoenixApp.Endpoint, []}, streaming: true
end

defmodule Mayfly.Plug.PhoenixPropagateHandler do
  @moduledoc false
  use Mayfly.Plug.Handler, plug: {Mayfly.Plug.PhoenixApp.Endpoint, []}, on_error: :propagate
end
