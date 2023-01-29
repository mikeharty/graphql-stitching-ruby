# frozen_string_literal: true

require "test_helper"

describe "GraphQL::Stitching::Plan, root operations" do

  def setup
    @widgets_sdl = "
      type Widget { id:ID! }
      type Query { widget: Widget }
      type Mutation { makeWidget: Widget }
    "

    @sprockets_sdl = "
      type Sprocket { id:ID! }
      type Query { sprocket: Sprocket }
      type Mutation { makeSprocket: Sprocket }
    "

    @graph_context = compose_definitions({
      "widgets" => @widgets_sdl,
      "sprockets" => @sprockets_sdl,
    })
  end

  def test_plans_by_given_operation_name
    document = GraphQL.parse("query First { widget { id } } query Second { sprocket { id } }")

    plan1 = GraphQL::Stitching::Plan.new(
      graph_context: @graph_context,
      document: document,
      operation_name: "First",
    ).plan

    assert_equal 1, plan1.operations.length
    assert_equal "widget", plan1.operations.first.selections.first.name

    plan2 = GraphQL::Stitching::Plan.new(
      graph_context: @graph_context,
      document: document,
      operation_name: "Second",
    ).plan

    assert_equal 1, plan2.operations.length
    assert_equal "sprocket", plan2.operations.first.selections.first.name
  end

  def test_errors_for_multiple_operations_given_without_operation_name
    document = GraphQL.parse("query First { widget { id } } query Second { sprocket { id } }")

    assert_error "An operation name is required" do
      GraphQL::Stitching::Plan.new(
        graph_context: @graph_context,
        document: document,
      ).plan
    end
  end

  def test_errors_for_invalid_operation_names
    document = GraphQL.parse("query First { widget { id } } query Second { sprocket { id } }")

    assert_error "Invalid root operation" do
      GraphQL::Stitching::Plan.new(
        graph_context: @graph_context,
        document: document,
        operation_name: "Invalid",
      ).plan
    end
  end

  def test_errors_for_invalid_operation_types
    graph_context = compose_definitions({ "widgets" => @widgets_sdl, "sprockets" => @sprockets_sdl })
    graph_context.schema.subscription(graph_context.schema.get_type("Widget"))
    document = GraphQL.parse("subscription { id }")

    assert_error "Invalid root operation" do
      GraphQL::Stitching::Plan.new(
        graph_context: @graph_context,
        document: document,
      ).plan
    end
  end

  def test_plans_query_operations_by_async_location_groups
    document = "
      query {
        a: widget { id }
        b: sprocket { id }
        c: widget { id }
        d: sprocket { id }
      }
    "

    plan = GraphQL::Stitching::Plan.new(
      graph_context: @graph_context,
      document: GraphQL.parse(document),
    ).plan

    assert_equal 2, plan.operations.length

    first = plan.operations[0]
    assert_equal "widgets", first.location
    assert_equal "query", first.operation_type
    assert_equal "{ a: widget { id } c: widget { id } }", first.selection_set
    assert_nil first.after_key

    second = plan.operations[1]
    assert_equal "sprockets", second.location
    assert_equal "query", second.operation_type
    assert_equal "{ b: sprocket { id } d: sprocket { id } }", second.selection_set
    assert_nil second.after_key
  end

  def test_plans_mutation_operations_by_serial_location_groups
    document = "
      mutation {
        a: makeWidget { id }
        b: makeSprocket { id }
        c: makeSprocket { id }
        d: makeWidget { id }
        e: makeWidget { id }
      }
    "

    plan = GraphQL::Stitching::Plan.new(
      graph_context: @graph_context,
      document: GraphQL.parse(document),
    ).plan

    assert_equal 3, plan.operations.length

    first = plan.operations[0]
    assert_equal "widgets", first.location
    assert_equal "mutation", first.operation_type
    assert_equal "{ a: makeWidget { id } }", first.selection_set
    assert_nil first.after_key

    second = plan.operations[1]
    assert_equal "sprockets", second.location
    assert_equal "mutation", second.operation_type
    assert_equal "{ b: makeSprocket { id } c: makeSprocket { id } }", second.selection_set
    assert_equal first.key, second.after_key

    third = plan.operations[2]
    assert_equal "widgets", third.location
    assert_equal "mutation", third.operation_type
    assert_equal "{ d: makeWidget { id } e: makeWidget { id } }", third.selection_set
    assert_equal second.key, third.after_key
  end
end
