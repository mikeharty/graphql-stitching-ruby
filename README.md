## GraphQL Stitching for Ruby

GraphQL stitching composes a single schema from multiple underlying GraphQL resources, then smartly delegates portions of incoming requests to their respective service locations in dependency order and returns the merged results. This allows an entire location graph to be queried through one combined GraphQL surface area.

![Stitched graph](./docs/images/stitching.png)

**Supports:**
- Merged object and interface types.
- Multiple keys per merged type.
- Shared objects, enums, and inputs across locations.
- Combining local and remote schemas.

**NOT Supported:**
- Computed fields (ie: federation-style `@requires`)
- Subscriptions

This Ruby implementation is a sibling of [GraphQL Tools](https://the-guild.dev/graphql/stitching) (JS) and [Bramble](https://movio.github.io/bramble/) (Go), and its capabilities fall somewhere in between them. GraphQL stitching is similar in concept to [Apollo Federation](https://www.apollographql.com/docs/federation/), though more generic. While Ruby is not the fastest language for a high-throughput API gateway, the opportunity here is for a Ruby application to stitch its local schema onto a remote schema (making itself a superset of the remote) without requiring an additional gateway service.

## Getting started

Add to your Gemfile, then `bundle install`:

```ruby
gem "graphql-stitching"
```

## Usage

The quickest way to start is to use the provided `Gateway` component that assembles a stitched graph ready to execute requests:

```ruby
movies_schema = <<~GRAPHQL
  type Movie { id: ID! name: String! }
  type Query { movie(id: ID!): Movie }
GRAPHQL

showtimes_schema = <<~GRAPHQL
  type Showtime { id: ID! time: String! }
  type Query { showtime(id: ID!): Showtime }
GRAPHQL

gateway = GraphQL::Stitching::Gateway.new({
  products: {
    schema: GraphQL::Schema.from_definition(movies_schema),
    client: GraphQL::Stitching::RemoteClient.new(url: "http://localhost:3000"),
  },
  showtimes: {
    schema: GraphQL::Schema.from_definition(showtimes_schema),
    client: GraphQL::Stitching::RemoteClient.new(url: "http://localhost:3001"),
  },
  my_local: {
    schema: MyLocal::GraphQL::Schema,
  },
})

result = gateway.execute(
  query: "query FetchFromAll($movieId:ID!, $showtimeId:ID!){
    movie(id:$movieId) { name }
    showtime(id:$showtimeId): { time }
    myLocalField
  }",
  variables: { "movieId" => "1", "showtimeId" => "2" },
  operation_name: "FetchFromAll"
)
```

Schemas provided to the `Gateway` constructor may be class-based schemas with local resolvers (locally-executable schemas), or schemas built from SDL strings (schema definition language parsed using `GraphQL::Schema.from_definition`) and mapped to remote locations.

While the `Gateway` component is an easy quick start, the library also has several discrete components that can be assembled into custom workflows:

- [Composer](./docs/composer.md) - merges and validates many schemas into one graph.
- [Supergraph](./docs/supergraph.md) - manages the combined schema and location routing maps. Can be exported, cached, and rehydrated.
- [Document](./docs/document.md) - manages a parsed GraphQL request document.
- [Planner](./docs/planner.md) - builds a cacheable query plan for a request document.
- [Executor](./docs/executor.md) - executes a query plan with given request variables.

## Merged types

`Object` and `Interface` types may exist with different fields in different graph locations, and will get merged together in the combined schema.

![Merging types](./docs/images/merging.png)

To facilitate this merging of types, stitching must know how to cross-reference and fetch each variant of a type from its source location. This is done using the `@stitch` directive:

```graphql
directive @stitch(key: String!) repeatable on FIELD_DEFINITION
```

This directive is applied to root queries where a merged type may be accessed in each location, and a `key` argument specifies a field needed from other locations to be used as a query argument.

```ruby
products_schema = <<~GRAPHQL
  directive @stitch(key: String!) repeatable on FIELD_DEFINITION

  type Product {
    id: ID!
    name: String!
  }

  type Query {
    product(id: ID!): Product @stitch(key: "id")
  }
GRAPHQL

shipping_schema = <<~GRAPHQL
  directive @stitch(key: String!) repeatable on FIELD_DEFINITION

  type Product {
    id: ID!
    weight: Float!
  }

  type Query {
    products(ids: [ID!]!): [Product]! @stitch(key: "id")
  }
GRAPHQL

supergraph = GraphQL::Stitching::Composer.new({
  "products" => GraphQL::Schema.from_definition(products_schema),
  "shipping" => GraphQL::Schema.from_definition(shipping_schema),
})

supergraph.assign_location_resource("products",
  GraphQL::Stitching::RemoteClient.new(url: "http://localhost:3001")
)
supergraph.assign_location_resource("shipping",
  GraphQL::Stitching::RemoteClient.new(url: "http://localhost:3002")
)
```

Focusing on the `@stitch` directive usage:

```graphql
type Product {
  id: ID!
  name: String!
}
type Query {
  product(id: ID!): Product @stitch(key: "id")
}
```

* The `@stitch` directive is applied to a root query where the merged type may be accessed. The merged type is inferred from the field return.
* The `key: "id"` parameter indicates that an `{ id }` must be selected from prior locations so it may be submitted as an argument to this query. The query argument used to send the key is inferred when possible (more on arguments later).

Each location that provides a unique variant of a type must provide _exactly one_ stitching query per possible key (more on multiple keys later). The exception to this requirement are types that contain only a single key field:

```graphql
type Product {
  id: ID!
}
```

The above representation of a `Product` type provides no unique data beyond a key that is available in other locations. Thus, this representation will never require an inbound request to fetch it, and its stitching query may be omitted. This pattern of providing key-only types is very common in stitching: it allows a foreign key to be represented as an object stub that may be enriched by data collected from other locations.

#### List queries

It's okay ([even preferable](https://www.youtube.com/watch?v=VmK0KBHTcWs) in many circumstances) to provide a list accessor as a stitching query. The only requirement is that both the field argument and return type must be lists, and the query results are expected to be a mapped set with `null` holding the position of missing results.

```graphql
type Query {
  products(ids: [ID!]!): [Product]! @stitch(key: "id")
}
```

#### Abstract queries

It's okay for stitching queries to be implemented through abstract types. An abstract query will provide access to all of its possible types. For interfaces, the key selection should match a field within the interface. For unions, all possible types must implement the key selection individually.

```graphql
interface Node {
  id: ID!
}
type Product implements Node {
  id: ID!
  name: String!
}
type Query {
  nodes(ids: [ID!]!): [Node]! @stitch(key: "id")
}
```

#### Multiple query arguments

Stitching infers which argument to use for queries with a single argument. For queries that accept multiple arguments, the key must provide an argument mapping specified as `"<arg>:<key>"`. Note the `"id:id"` key:

```graphql
type Query {
  product(id: ID, upc: ID): Product @stitch(key: "id:id")
}
```

#### Multiple query keys

A type may exist in multiple locations across the graph using different keys, for example:

```graphql
type Product { id:ID! }          # storefronts location
type Product { id:ID! upc:ID! }  # products location
type Product { upc:ID! }         # catelog location
```

In the above graph, the `storefronts` and `catelog` locations have different keys that join through an intermediary. This pattern is perfectly valid and resolvable as long as the intermediary provides stitching queries for each possible key:

```graphql
type Product {
  id: ID!
  upc: ID!
}
type Query {
  productById(id: ID): Product @stitch(key: "id")
  productByUpc(upc: ID): Product @stitch(key: "upc")
}
```

The `@stitch` directive is also repeatable, allowing a single query to associate with multiple keys:

```graphql
type Product {
  id: ID!
  upc: ID!
}
type Query {
  product(id: ID, upc: ID): Product @stitch(key: "id:id") @stitch(key: "upc:upc")
}
```

#### Class-based schemas

The `@stitch` directive can be added to class-based schemas with a directive class:

```ruby
class StitchField < GraphQL::Schema::Directive
  graphql_name "stitch"
  locations FIELD_DEFINITION
  repeatable true
  argument :key, String, required: true
end

class Query < GraphQL::Schema::Object
  field :product, Product, null: false do
    directive StitchField, key: "id"
    argument :id, ID, required: true
  end
end
```

#### Custom directive names

The library is configured to use a `@stitch` directive by default. You may customize this by setting a new name during initialization:

```ruby
GraphQL::Stitching.stitch_directive = "merge"
```

## Executable resources

A [Supergraph](./docs/supergraph.md) will delegate requests to the individual `GraphQL::Schema` instances that composed it by default. You may change this behavior by assigning new resource for any location. An executable resource is a `GraphQL::Schema` class, or any object that responds to `.call` (procs, lambdas, custom class objects, etc).

```ruby
class MyExecutableResource
  def call(location, query_string, variables)
    # process a GraphQL request...
  end
end
```

These resources can be assigned to the supergraph instance using `assign_executable`:

```ruby
supergraph = GraphQL::Stitching::Composer.new(...)

supergraph.assign_executable("location1", MyExecutableResource.new)
supergraph.assign_executable("location2", ->(loc, query, vars) { ... })
supergraph.assign_executable("location3") do |loc, query vars|
  # ...
end
```

The `GraphQL::Stitching::RemoteClient` class is provided as a simple wrapper around `Net::HTTP.post`. You should build your own wrappers to leverage existing libraries and provide instrumentation.

## Concurrency

The [Executor](./docs/executor.md) component performs all GraphQL requests, and structures its execution around the `GraphQL::Dataloader` implementation built atop Ruby fibers. Non-blocking concurrency requires setting a fiber scheduler implementation via `Fiber.set_scheduler`, see [official docs](https://graphql-ruby.org/dataloader/nonblocking.html). You may also need your own remote client using corresponding HTTP libraries.

## Example

This repo includes a working example of three stitched schemas running across Rack servers. Try running it:

```shell
bundle install
foreman start
```

Then visit the gateway service at `http://localhost:3000` and try this query:

```graphql
query {
  storefront(id: "1") {
    id
    products {
      upc
      name
      price
      manufacturer {
        name
        address
        products { upc name }
      }
    }
  }
}
```

The above query collects data from all three locations, two of which are remote schemas and the third a local schema. The combined graph schema is also stitched in to provide introspection capabilities.

## Tests

```shell
bundle install
bundle exec rake test [TEST=path/to/test.rb]
```
