# frozen_string_literal: true

module GraphQL
  module Stitching
    class Executor::BoundarySource < GraphQL::Dataloader::Source
      def initialize(executor, location)
        @executor = executor
        @location = location
      end

      def fetch(ops)
        origin_sets_by_operation = ops.each_with_object({}) do |op, memo|
          origin_set = op.path.reduce([@executor.data]) do |set, path_segment|
            set.flat_map { |obj| obj && obj[path_segment] }.tap(&:compact!)
          end

          if op.if_type
            # operations planned around unused fragment conditions should not trigger requests
            origin_set.select! { _1[ExportSelection.typename_node.alias] == op.if_type }
          end

          memo[op] = origin_set if origin_set.any?
        end

        if origin_sets_by_operation.any?
          query_document, variable_names = build_document(
            origin_sets_by_operation,
            @executor.request.operation_name,
            @executor.request.operation_directives,
          )
          variables = @executor.request.variables.slice(*variable_names)
          raw_result = @executor.supergraph.execute_at_location(@location, query_document, variables, @executor.request.context)
          @executor.query_count += 1

          merge_results!(origin_sets_by_operation, raw_result.dig("data"))

          errors = raw_result.dig("errors")
          @executor.errors.concat(extract_errors!(origin_sets_by_operation, errors)) if errors&.any?
        end

        ops.map { origin_sets_by_operation[_1] ? _1.step : nil }
      end

      # Builds batched boundary queries
      # "query MyOperation_2_3($var:VarType) {
      #   _0_result: list(keys:["a","b","c"]) { boundarySelections... }
      #   _1_0_result: item(key:"x") { boundarySelections... }
      #   _1_1_result: item(key:"y") { boundarySelections... }
      #   _1_2_result: item(key:"z") { boundarySelections... }
      # }"
      def build_document(origin_sets_by_operation, operation_name = nil, operation_directives = nil)
        variable_defs = {}
        query_fields = origin_sets_by_operation.map.with_index do |(op, origin_set), batch_index|
          variable_defs.merge!(op.variables)
          boundary = op.boundary

          if boundary.list
            input = origin_set.each_with_index.reduce(String.new) do |memo, (origin_obj, index)|
              memo << "," if index > 0
              memo << build_key(boundary.key, origin_obj, federation: boundary.federation)
              memo
            end

            "_#{batch_index}_result: #{boundary.field}(#{boundary.arg}:[#{input}]) #{op.selections}"
          else
            origin_set.map.with_index do |origin_obj, index|
              input = build_key(boundary.key, origin_obj, federation: boundary.federation)
              "_#{batch_index}_#{index}_result: #{boundary.field}(#{boundary.arg}:#{input}) #{op.selections}"
            end
          end
        end

        doc = String.new("query") # << boundary fulfillment always uses query

        if operation_name
          doc << " #{operation_name}"
          origin_sets_by_operation.each_key do |op|
            doc << "_#{op.step}"
          end
        end

        if variable_defs.any?
          variable_str = variable_defs.map { |k, v| "$#{k}:#{v}" }.join(",")
          doc << "(#{variable_str})"
        end

        if operation_directives
          doc << " #{operation_directives} "
        end

        doc << "{ #{query_fields.join(" ")} }"

        return doc, variable_defs.keys
      end

      def build_key(key, origin_obj, federation: false)
        key_value = JSON.generate(origin_obj[ExportSelection.key(key)])
        if federation
          "{ __typename: \"#{origin_obj[ExportSelection.typename_node.alias]}\", #{key}: #{key_value} }"
        else
          key_value
        end
      end

      def merge_results!(origin_sets_by_operation, raw_result)
        return unless raw_result

        origin_sets_by_operation.each_with_index do |(op, origin_set), batch_index|
          results = if op.dig("boundary", "list")
            raw_result["_#{batch_index}_result"]
          else
            origin_set.map.with_index { |_, index| raw_result["_#{batch_index}_#{index}_result"] }
          end

          next unless results&.any?

          origin_set.each_with_index do |origin_obj, index|
            origin_obj.merge!(results[index]) if results[index]
          end
        end
      end

      # https://spec.graphql.org/June2018/#sec-Errors
      def extract_errors!(origin_sets_by_operation, errors)
        ops = origin_sets_by_operation.keys
        origin_sets = origin_sets_by_operation.values
        pathed_errors_by_op_index_and_object_id = {}

        errors_result = errors.each_with_object([]) do |err, memo|
          err.delete("locations")
          path = err["path"]

          if path && path.length > 0
            result_alias = /^_(\d+)(?:_(\d+))?_result$/.match(path.first.to_s)

            if result_alias
              path = err["path"] = path[1..-1]

              origin_obj = if result_alias[2]
                origin_sets.dig(result_alias[1].to_i, result_alias[2].to_i)
              elsif path[0].is_a?(Integer) || /\d+/.match?(path[0].to_s)
                origin_sets.dig(result_alias[1].to_i, path.shift.to_i)
              end

              if origin_obj
                by_op_index = pathed_errors_by_op_index_and_object_id[result_alias[1].to_i] ||= {}
                by_object_id = by_op_index[origin_obj.object_id] ||= []
                by_object_id << err
                next
              end
            end
          end

          memo << err
        end

        if pathed_errors_by_op_index_and_object_id.any?
          pathed_errors_by_op_index_and_object_id.each do |op_index, pathed_errors_by_object_id|
            repath_errors!(pathed_errors_by_object_id, ops.dig(op_index, "path"))
            errors_result.concat(pathed_errors_by_object_id.values)
          end
        end
        errors_result.flatten!
      end

      private

      # traverse forward through origin data, expanding arrays to follow all paths
      # any errors found for an origin object_id have their path prefixed by the object path
      def repath_errors!(pathed_errors_by_object_id, forward_path, current_path=[], root=@executor.data)
        current_path.push(forward_path.shift)
        scope = root[current_path.last]

        if forward_path.any? && scope.is_a?(Array)
          scope.each_with_index do |element, index|
            inner_elements = element.is_a?(Array) ? element.flatten : [element]
            inner_elements.each do |inner_element|
              current_path << index
              repath_errors!(pathed_errors_by_object_id, forward_path, current_path, inner_element)
              current_path.pop
            end
          end

        elsif forward_path.any?
          current_path << index
          repath_errors!(pathed_errors_by_object_id, forward_path, current_path, scope)
          current_path.pop

        elsif scope.is_a?(Array)
          scope.each_with_index do |element, index|
            inner_elements = element.is_a?(Array) ? element.flatten : [element]
            inner_elements.each do |inner_element|
              errors = pathed_errors_by_object_id[inner_element.object_id]
              errors.each { _1["path"] = [*current_path, index, *_1["path"]] } if errors
            end
          end

        else
          errors = pathed_errors_by_object_id[scope.object_id]
          errors.each { _1["path"] = [*current_path, *_1["path"]] } if errors
        end

        forward_path.unshift(current_path.pop)
      end
    end
  end
end
