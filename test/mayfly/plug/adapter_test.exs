defmodule Mayfly.Plug.AdapterTest do
  use ExUnit.Case, async: true

  alias Mayfly.Plug.{Adapter, Fixtures}

  @ctx %Mayfly.Context{request_id: "ctx-1", deadline_ms: 0}

  describe "conn/3 from a v2 event" do
    test "method, path, query, host, scheme, ip, headers, cookies, context" do
      conn = Adapter.conn(Fixtures.v2(), @ctx)

      assert %Plug.Conn{method: "POST", request_path: "/items/42", path_info: ["items", "42"]} =
               conn

      assert conn.query_string == "a=1&a=2&b=x%20y"
      assert Plug.Conn.fetch_query_params(conn).query_params == %{"a" => "2", "b" => "x y"}
      assert conn.host == "abc.lambda-url.eu-central-1.on.aws"
      assert conn.scheme == :https and conn.port == 443
      assert conn.remote_ip == {203, 0, 113, 9}
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "cookie") == ["session=abc; theme=dark"]
      assert Plug.Conn.fetch_cookies(conn).req_cookies == %{"session" => "abc", "theme" => "dark"}
      assert conn.private.mayfly_context == @ctx
      assert conn.assigns.lambda_context == @ctx

      assert Adapter.get_peer_data(elem(conn.adapter, 1)) == %{
               address: {203, 0, 113, 9},
               port: 0,
               ssl_cert: nil
             }

      assert Adapter.get_http_protocol(elem(conn.adapter, 1)) == :"HTTP/1.1"
    end

    test "body is readable once, raw (not pre-decoded)" do
      conn = Adapter.conn(Fixtures.v2(), @ctx)
      assert {:ok, ~s({"name":"widget"}), conn} = Plug.Conn.read_body(conn)
      assert {:ok, "", _} = Plug.Conn.read_body(conn)
    end

    test "large bodies honour :length with :more" do
      conn = Adapter.conn(Fixtures.v2(%{"body" => String.duplicate("x", 10)}), @ctx)
      assert {:more, "xxxx", conn} = Plug.Conn.read_body(conn, length: 4)
      assert {:ok, "xxxxxx", _} = Plug.Conn.read_body(conn, length: 100)
    end

    test "base64 body is decoded" do
      conn =
        Adapter.conn(
          Fixtures.v2(%{"body" => Base.encode64(<<1, 2, 3>>), "isBase64Encoded" => true}),
          @ctx
        )

      assert {:ok, <<1, 2, 3>>, _} = Plug.Conn.read_body(conn)
    end
  end

  describe "conn/3 from a v1 event" do
    test "multi-value headers stay separate, query string is rebuilt, cookies parsed" do
      conn = Adapter.conn(Fixtures.v1(), @ctx)
      assert conn.method == "GET" and conn.request_path == "/search"
      assert Plug.Conn.get_req_header(conn, "x-tag") == ["one", "two"]

      assert Plug.Conn.fetch_query_params(conn).query_params == %{
               "q" => "elixir lambda",
               "page" => "3"
             }

      assert Plug.Conn.fetch_cookies(conn).req_cookies == %{"a" => "1", "b" => "2"}
      assert conn.remote_ip == {198, 51, 100, 7}
      assert {:ok, "", _} = Plug.Conn.read_body(conn)
    end
  end

  describe "conn/3 from an ALB event" do
    test "x-forwarded-* drive scheme/port/ip; encoded query is kept verbatim; binary body decoded" do
      conn = Adapter.conn(Fixtures.alb(), @ctx)
      assert conn.scheme == :http and conn.port == 80 and conn.host == "alb.example.com"
      # last X-Forwarded-For hop: the address the load balancer itself saw
      assert conn.remote_ip == {10, 0, 0, 2}
      assert Plug.Conn.fetch_query_params(conn).query_params == %{"v" => "1", "name" => "a b"}
      assert {:ok, <<0, 1, 2, 255>>, _} = Plug.Conn.read_body(conn)
    end
  end

  describe "proxy_response/1" do
    test "v2: text body, set-cookie into cookies, no base64" do
      conn =
        Adapter.conn(
          Fixtures.v2(%{
            "rawPath" => "/cookie",
            "requestContext" => put_in(Fixtures.v2()["requestContext"], ["http", "method"], "GET")
          }),
          @ctx
        )

      conn = Mayfly.Plug.TestRouter.call(conn, [])

      assert {:ok,
              %{
                statusCode: 204,
                body: "",
                isBase64Encoded: false,
                cookies: cookies,
                headers: headers
              }} = Adapter.proxy_response(conn)

      assert Enum.any?(cookies, &String.starts_with?(&1, "sid=s1;")) and
               Enum.any?(cookies, &String.starts_with?(&1, "theme=light"))

      refute Map.has_key?(headers, "set-cookie")
      assert headers["cache-control"] =~ "max-age=0"
    end

    test "v1: set-cookie stays a header, repeated ones go to multiValueHeaders" do
      conn =
        Adapter.conn(Fixtures.v1(%{"path" => "/cookie"}), @ctx) |> Mayfly.Plug.TestRouter.call([])

      assert {:ok, %{statusCode: 204, multiValueHeaders: %{"set-cookie" => [_, _]}} = r} =
               Adapter.proxy_response(conn)

      refute Map.has_key?(r, :cookies)
    end

    test "ALB adds statusDescription" do
      conn =
        Adapter.conn(Fixtures.alb(%{"httpMethod" => "GET", "path" => "/nothing"}), @ctx)
        |> Mayfly.Plug.TestRouter.call([])

      assert {:ok, %{statusCode: 404, statusDescription: "404 Not Found", body: "nope"}} =
               Adapter.proxy_response(conn)
    end

    test "binary content type is base64 encoded" do
      conn =
        Adapter.conn(Fixtures.v1(%{"path" => "/png"}), @ctx) |> Mayfly.Plug.TestRouter.call([])

      assert {:ok, %{statusCode: 200, isBase64Encoded: true, body: body}} =
               Adapter.proxy_response(conn)

      assert Base.decode64!(body) == <<137, 80, 78, 71, 0, 0>>
    end

    test "non-UTF-8 text body is base64 encoded too" do
      resp =
        Adapter.to_proxy(
          %Mayfly.Events.HTTP.Request{version: :v2},
          %{status: 200, headers: [{"content-type", "text/plain"}], body: <<255, 254>>},
          Adapter.default_binary_types()
        )

      assert resp.isBase64Encoded and Base.decode64!(resp.body) == <<255, 254>>
    end

    test "send_file reads the file" do
      conn =
        Adapter.conn(Fixtures.v1(%{"path" => "/file"}), @ctx) |> Mayfly.Plug.TestRouter.call([])

      assert {:ok, %{statusCode: 200, body: body, isBase64Encoded: false}} =
               Adapter.proxy_response(conn)

      assert body =~ "defmodule Mayfly.Plug.TestRouter"
    end

    test "buffered chunked response is flattened" do
      conn =
        Adapter.conn(Fixtures.v1(%{"path" => "/chunked"}), @ctx)
        |> Mayfly.Plug.TestRouter.call([])

      assert {:ok, %{statusCode: 200, body: "part1;part2;part3;"}} = Adapter.proxy_response(conn)
    end

    test "HEAD drops the body" do
      conn =
        Adapter.conn(Fixtures.v1(%{"path" => "/anything", "httpMethod" => "HEAD"}), @ctx)
        |> Mayfly.Plug.TestRouter.call([])

      # the catch-all sends "nope" with 404; HEAD must not carry it
      assert {:ok, %{statusCode: 404, body: ""}} = Adapter.proxy_response(conn)
    end

    test "no response" do
      conn =
        Adapter.conn(Fixtures.v1(%{"path" => "/no-response"}), @ctx)
        |> Mayfly.Plug.TestRouter.call([])

      assert {:error, :no_response} = Adapter.proxy_response(conn)
    end
  end

  test "binary_content_type?/2" do
    assert Adapter.binary_content_type?("image/png", Adapter.default_binary_types())
    assert Adapter.binary_content_type?("Application/PDF; name=x", Adapter.default_binary_types())

    refute Adapter.binary_content_type?(
             "application/vnd.api+json",
             Adapter.default_binary_types()
           )

    refute Adapter.binary_content_type?(
             "text/html; charset=utf-8",
             Adapter.default_binary_types()
           )

    refute Adapter.binary_content_type?(nil, Adapter.default_binary_types())
    assert Adapter.binary_content_type?("text/csv", ["text/csv"])
  end

  test "inform/upgrade are not supported; http_event? classifies" do
    payload = Adapter.conn(Fixtures.v2(), @ctx).adapter |> elem(1)
    assert {:error, :not_supported} = Adapter.inform(payload, 103, [])
    assert {:error, :not_supported} = Adapter.upgrade(payload, :websocket, [])

    assert Adapter.http_event?(Fixtures.v1()) and Adapter.http_event?(Fixtures.v2()) and
             Adapter.http_event?(Fixtures.alb())

    refute Adapter.http_event?(%{"Records" => []})
  end
end
