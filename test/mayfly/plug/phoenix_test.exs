defmodule Mayfly.Plug.PhoenixTest do
  # A real Phoenix 1.8 endpoint (test/support/phoenix_app.ex) through the runtime.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Mayfly.LocalRuntime
  alias Mayfly.Plug.Fixtures

  setup_all do
    start_supervised!(Mayfly.Plug.PhoenixApp.Endpoint)
    :ok
  end

  defp start_runtime(handler) do
    rt = start_supervised!({LocalRuntime, []}, id: make_ref())

    {:ok, _} =
      Mayfly.start_link(handler: handler, runtime_api: LocalRuntime.address(rt), name: nil)

    rt
  end

  defp get(path, extra \\ %{}) do
    Fixtures.v2(
      Map.merge(
        %{
          "rawPath" => path,
          "rawQueryString" => "",
          "queryStringParameters" => %{},
          "body" => nil,
          "cookies" => [],
          "requestContext" => put_in(Fixtures.v2()["requestContext"], ["http", "method"], "GET")
        },
        extra
      )
    )
  end

  defp invoke(rt, event) do
    {:ok, %{body: body}} = LocalRuntime.invoke(rt, event)
    JSON.decode!(body)
  end

  test "controller action with context, Plug.Parsers JSON body, Phoenix 404 and 500 rendering" do
    rt = start_runtime("Mayfly.Plug.PhoenixHandler")

    resp =
      invoke(
        rt,
        get("/api/hello", %{
          "rawQueryString" => "name=Ada",
          "queryStringParameters" => %{"name" => "Ada"}
        })
      )

    assert resp["statusCode"] == 200
    assert resp["headers"]["content-type"] =~ "application/json"
    assert %{"hello" => "Ada", "request_id" => rid} = JSON.decode!(resp["body"])
    assert is_binary(rid)
    assert resp["headers"]["x-request-id"]

    resp =
      invoke(
        rt,
        Fixtures.v2(%{
          "rawPath" => "/api/items",
          "rawQueryString" => "",
          "queryStringParameters" => %{},
          "body" => ~s({"sku":"A1","qty":2})
        })
      )

    assert %{"statusCode" => 201, "headers" => %{"x-created" => "1"}} = resp
    assert JSON.decode!(resp["body"]) == %{"received" => %{"sku" => "A1", "qty" => 2}}

    resp = invoke(rt, get("/api/nothing"))
    assert resp["statusCode"] == 404
    assert JSON.decode!(resp["body"]) == %{"errors" => %{"detail" => "Not Found"}}

    # Phoenix.Endpoint.RenderErrors renders the 500 then re-raises; default on_error: :respond returns it.
    resp = invoke(rt, get("/api/boom"))
    assert resp["statusCode"] == 500
    assert JSON.decode!(resp["body"]) == %{"errors" => %{"detail" => "Internal Server Error"}}
  end

  test "cookie session survives a round trip through the v2 cookies list" do
    rt = start_runtime("Mayfly.Plug.PhoenixHandler")
    first = invoke(rt, get("/api/count"))
    assert %{"counter" => 1} = JSON.decode!(first["body"])
    [cookie | _] = first["cookies"]
    assert cookie =~ "_mayfly_plug_test="

    second = invoke(rt, get("/api/count", %{"cookies" => [cookie |> String.split(";") |> hd()]}))
    assert %{"counter" => 2} = JSON.decode!(second["body"])
  end

  test "on_error: :propagate surfaces the exception Phoenix rendered" do
    rt = start_runtime("Mayfly.Plug.PhoenixPropagateHandler")

    assert {:error, %{"errorType" => "RuntimeError", "errorMessage" => "phoenix failure"}} =
             LocalRuntime.invoke(rt, get("/api/boom"))
  end

  test "send_chunked from a controller streams with the prelude" do
    rt = start_runtime("Mayfly.Plug.PhoenixStreamingHandler")
    assert {:ok, %{body: body, headers: headers}} = LocalRuntime.invoke(rt, get("/api/stream"))
    assert {"lambda-runtime-function-response-mode", "streaming"} in headers
    [prelude, payload] = String.split(body, <<0, 0, 0, 0, 0, 0, 0, 0>>)

    assert %{"statusCode" => 200, "headers" => %{"content-type" => "text/plain; charset=utf-8"}} =
             JSON.decode!(prelude)

    assert payload == "tick 1\ntick 2\ntick 3\n"
  end

  test "HEAD via Plug.Head and 404 with v1 event shape" do
    rt = start_runtime("Mayfly.Plug.PhoenixHandler")

    event =
      Fixtures.v1(%{
        "path" => "/api/hello",
        "httpMethod" => "HEAD",
        "headers" => %{"Host" => "api.example.com", "Accept" => "application/json"},
        "multiValueHeaders" => %{"Host" => ["api.example.com"], "Accept" => ["application/json"]}
      })

    assert %{"statusCode" => 200, "body" => ""} = invoke(rt, event)

    # Accept: text/plain is answered by Phoenix with 406 (rendered via RenderErrors)
    resp = invoke(rt, Fixtures.v1(%{"path" => "/api/hello"}))
    assert resp["statusCode"] == 406
  end

  test "streaming: Phoenix raising after a chunk does not render a second response; error via trailers" do
    rt = start_runtime("Mayfly.Plug.PhoenixStreamingHandler")

    assert {:ok, %{body: body, trailers: trailers}} =
             LocalRuntime.invoke(rt, get("/api/stream-boom"))

    [prelude, payload] = String.split(body, <<0, 0, 0, 0, 0, 0, 0, 0>>)
    assert %{"statusCode" => 200} = JSON.decode!(prelude)
    # RenderErrors saw {:plug_conn, :sent} in the plug process and did NOT emit a 500 body
    assert payload == "partial\n"
    assert trailers["lambda-runtime-function-error-type"] =~ "RuntimeError"
  end

  test "buffered: the poller mailbox is clean after a rendered Phoenix 500" do
    rt = start_runtime("Mayfly.Plug.PhoenixHandler")
    resp = invoke(rt, get("/api/boom"))
    assert resp["statusCode"] == 500
    resp = invoke(rt, get("/api/hello"))
    assert resp["statusCode"] == 200
  end
end
