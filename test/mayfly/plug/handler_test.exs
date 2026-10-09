defmodule Mayfly.Plug.HandlerTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Mayfly.LocalRuntime
  alias Mayfly.Plug.Fixtures

  defp start_runtime(handler) do
    rt = start_supervised!({LocalRuntime, []}, id: make_ref())

    {:ok, _} =
      Mayfly.start_link(handler: handler, runtime_api: LocalRuntime.address(rt), name: nil)

    rt
  end

  defp invoke(rt, event) do
    case LocalRuntime.invoke(rt, event) do
      {:ok, %{body: body} = r} -> {:ok, JSON.decode!(body), r}
      {:error, _} = e -> e
    end
  end

  describe "buffered handler through the runtime" do
    test "GET JSON with context and query" do
      rt = start_runtime("Mayfly.Plug.TestHandler")

      {:ok, resp, _} =
        invoke(
          rt,
          Fixtures.v2(%{
            "rawPath" => "/items/7",
            "rawQueryString" => "x=1",
            "requestContext" => put_in(Fixtures.v2()["requestContext"], ["http", "method"], "GET")
          })
        )

      assert %{"statusCode" => 200, "cookies" => [], "isBase64Encoded" => false} = resp

      assert %{"id" => "7", "query" => %{"x" => "1"}, "request_id" => rid} =
               JSON.decode!(resp["body"])

      assert is_binary(rid)
    end

    test "POST form (urlencoded) and POST JSON" do
      rt = start_runtime("Mayfly.Plug.TestHandler")

      form =
        Fixtures.v1(%{
          "path" => "/form",
          "httpMethod" => "POST",
          "multiValueHeaders" => %{
            "Host" => ["h"],
            "Content-Type" => ["application/x-www-form-urlencoded"]
          },
          "body" => "name=Ada"
        })

      {:ok, resp, _} = invoke(rt, form)

      assert %{"statusCode" => 201, "body" => "hello Ada", "headers" => %{"x-echo" => "yes"}} =
               resp

      {:ok, resp, _} = invoke(rt, Fixtures.v2())
      assert %{"statusCode" => 200, "body" => ~s({"name":"widget"})} = resp
      assert resp["headers"]["content-type"] =~ "application/json"
    end

    test "404 from the router" do
      rt = start_runtime("Mayfly.Plug.TestHandler")

      {:ok, %{"statusCode" => 404, "body" => "nope"}, _} =
        invoke(rt, Fixtures.v1(%{"path" => "/missing"}))
    end

    test "an exception without an error handler propagates as a Lambda error" do
      rt = start_runtime("Mayfly.Plug.TestHandler")

      assert {:error,
              %{
                "errorType" => "ArgumentError",
                "errorMessage" => "kaboom",
                "stackTrace" => [_ | _]
              }} = invoke(rt, Fixtures.v1(%{"path" => "/boom"}))
    end

    test "Plug.ErrorHandler: rendered 500 is returned (on_error: :respond)" do
      rt = start_runtime("Mayfly.Plug.ErrorHandlerHandler")

      {:ok, %{"statusCode" => 500, "body" => "rendered: kaboom"}, _} =
        invoke(rt, Fixtures.v1(%{"path" => "/boom"}))
    end

    test "Plug.ErrorHandler with on_error: :propagate surfaces the exception" do
      rt = start_runtime("Mayfly.Plug.PropagateHandler")

      assert {:error, %{"errorType" => "ArgumentError", "errorMessage" => "kaboom"}} =
               invoke(rt, Fixtures.v1(%{"path" => "/boom"}))
    end

    test "plug without a response is an error" do
      rt = start_runtime("Mayfly.Plug.TestHandler")

      assert {:error, %{"errorType" => "Mayfly.Plug.NoResponse"}} =
               invoke(rt, Fixtures.v1(%{"path" => "/no-response"}))
    end

    test "non-HTTP events are rejected" do
      rt = start_runtime("Mayfly.Plug.TestHandler")

      assert {:error, %{"errorType" => "Mayfly.Plug.NotAnHttpEvent", "errorMessage" => msg}} =
               invoke(rt, %{"Records" => [%{"eventSource" => "aws:sqs"}]})

      assert msg =~ "Records"
    end
  end

  describe "streaming handler" do
    test "chunked route streams with the Function URL prelude" do
      rt = start_runtime("Mayfly.Plug.StreamingHandler")

      assert {:ok, %{status: 200, body: body, headers: headers}} =
               LocalRuntime.invoke(rt, Fixtures.v1(%{"path" => "/chunked"}))

      assert {"lambda-runtime-function-response-mode", "streaming"} in headers
      assert {"content-type", "application/vnd.awslambda.http-integration-response"} in headers
      [prelude, payload] = String.split(body, <<0, 0, 0, 0, 0, 0, 0, 0>>)

      assert %{
               "statusCode" => 200,
               "headers" => %{"content-type" => "text/plain; charset=utf-8"},
               "cookies" => []
             } = JSON.decode!(prelude)

      assert payload == "part1;part2;part3;"
    end

    test "a plain send_resp is still delivered as a (one-chunk) stream" do
      rt = start_runtime("Mayfly.Plug.StreamingHandler")

      assert {:ok, %{status: 200, body: body}} =
               LocalRuntime.invoke(rt, Fixtures.v1(%{"path" => "/missing"}))

      [prelude, "nope"] = String.split(body, <<0, 0, 0, 0, 0, 0, 0, 0>>)
      assert %{"statusCode" => 404} = JSON.decode!(prelude)
    end

    test "exception before any response propagates" do
      rt = start_runtime("Mayfly.Plug.StreamingHandler")

      assert {:error, %{"errorType" => "ArgumentError", "errorMessage" => "kaboom"}} =
               LocalRuntime.invoke(rt, Fixtures.v1(%{"path" => "/boom"}))
    end

    test "mid-stream exception is reported via trailers after the sent chunks" do
      rt = start_runtime("Mayfly.Plug.StreamingHandler")

      assert {:ok, %{body: body, trailers: trailers}} =
               LocalRuntime.invoke(rt, Fixtures.v1(%{"path" => "/chunked-boom"}))

      assert body =~ "start;"
      assert trailers["lambda-runtime-function-error-type"] =~ "RuntimeError"
    end
  end
end
