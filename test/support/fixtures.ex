defmodule Mayfly.Plug.Fixtures do
  @moduledoc false

  def v2(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => "2.0",
        "routeKey" => "$default",
        "rawPath" => "/items/42",
        "rawQueryString" => "a=1&a=2&b=x%20y",
        "cookies" => ["session=abc", "theme=dark"],
        "headers" => %{
          "Host" => "abc.lambda-url.eu-central-1.on.aws",
          "Content-Type" => "application/json",
          "X-Forwarded-Proto" => "https",
          "X-Forwarded-Port" => "443",
          "User-Agent" => "curl/8"
        },
        "queryStringParameters" => %{"a" => "1,2", "b" => "x y"},
        "requestContext" => %{
          "http" => %{
            "method" => "POST",
            "path" => "/items/42",
            "protocol" => "HTTP/1.1",
            "sourceIp" => "203.0.113.9",
            "userAgent" => "curl/8"
          },
          "requestId" => "req-1",
          "stage" => "$default"
        },
        "body" => ~s({"name":"widget"}),
        "isBase64Encoded" => false
      },
      overrides
    )
  end

  def v1(overrides \\ %{}) do
    Map.merge(
      %{
        "resource" => "/{proxy+}",
        "path" => "/search",
        "httpMethod" => "GET",
        "headers" => %{
          "Host" => "api.example.com",
          "Accept" => "text/plain",
          "Cookie" => "a=1; b=2"
        },
        "multiValueHeaders" => %{
          "Host" => ["api.example.com"],
          "Accept" => ["text/plain"],
          "Cookie" => ["a=1; b=2"],
          "X-Tag" => ["one", "two"]
        },
        "queryStringParameters" => %{"q" => "elixir lambda", "page" => "3"},
        "multiValueQueryStringParameters" => %{"q" => ["elixir lambda"], "page" => ["3"]},
        "requestContext" => %{
          "requestId" => "req-v1",
          "stage" => "prod",
          "identity" => %{"sourceIp" => "198.51.100.7", "userAgent" => "test"}
        },
        "body" => nil,
        "isBase64Encoded" => false
      },
      overrides
    )
  end

  def alb(overrides \\ %{}) do
    Map.merge(
      %{
        "requestContext" => %{"elb" => %{"targetGroupArn" => "arn:aws:elasticloadbalancing:..."}},
        "httpMethod" => "POST",
        "path" => "/upload",
        "multiValueQueryStringParameters" => %{"v" => ["1"], "name" => ["a%20b"]},
        "multiValueHeaders" => %{
          "host" => ["alb.example.com"],
          "content-type" => ["application/octet-stream"],
          "x-forwarded-for" => ["192.0.2.1, 10.0.0.2"],
          "x-forwarded-proto" => ["http"],
          "x-forwarded-port" => ["80"]
        },
        "body" => Base.encode64(<<0, 1, 2, 255>>),
        "isBase64Encoded" => true
      },
      overrides
    )
  end
end
