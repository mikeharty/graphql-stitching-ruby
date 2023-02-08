# frozen_string_literal: true

require 'rackup'
require 'json'
require 'graphql'
require_relative '../test/schemas/example'

class SecondRemoteApp
  def call(env)
    req = Rack::Request.new(env)
    case req.path_info
    when /graphql/
      params = JSON.parse(req.body.read)
      result = Schemas::Example::Manufacturers.execute(
        query: params["query"],
        variables: params["variables"],
        operation_name: params["operationName"],
      )
      [200, {"content-type" => "application/json"}, [JSON.generate(result)]]
    else
      [404, {"content-type" => "text/html"}, ["not found"]]
    end
  end
end

Rackup::Handler.default.run(SecondRemoteApp.new, :Port => 3002)
