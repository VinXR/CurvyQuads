# frozen_string_literal: true

module MarcelloPanicciaTools
  module CurvyQuads
    module TopologyNavigator
      # Analyzes a single vertex atomically to find P0, P1, P2, P3 and internal vertices
      # for Catmull-Rom curve generation.
      #
      # Algorithm:
      # 1. Find an edge orthogonal to selected edges (row direction)
      # 2. Traverse in one direction collecting selected vertices
      # 3. Find first non-selected vertex (anchor) and next (control)
      # 4. Traverse in opposite direction from original vertex
      # 5. Find opposite anchor and control
      #
      # @param vertex [Sketchup::Vertex] Starting vertex (must be in selection)
      # @param selected_edges [Array<Sketchup::Edge>] User's edge selection
      # @return [Hash, nil] Hash with :P0, :P1, :P2, :P3, :internal_vertices, or nil if invalid
      def self.analyze_vertex(vertex, selected_edges)
        selected_vertices_set = extract_vertices_from_edges(selected_edges)

        # Vertex must be in selection
        return nil unless selected_vertices_set.include?(vertex)

        # Find an orthogonal edge (not in selection) to start row traversal
        orthogonal_edge = find_orthogonal_edge(vertex, selected_edges)
        return nil unless orthogonal_edge

        # Get direction vector for this edge
        other_vertex = orthogonal_edge.other_vertex(vertex)
        direction = (other_vertex.position - vertex.position).normalize

        # Traverse in the direction of orthogonal_edge (e.g., right →)
        result_forward = traverse_direction(vertex, orthogonal_edge, direction, selected_vertices_set, selected_edges)

        # Traverse in opposite direction (e.g., left ←)
        direction_backward = direction.reverse
        opposite_edge = find_continuation_edge(vertex, nil, direction_backward, selected_edges)

        if opposite_edge
          result_backward = traverse_direction(vertex, opposite_edge, direction_backward, selected_vertices_set, selected_edges)
        else
          # Boundary case: vertex is at mesh edge, no vertices in backward direction
          result_backward = {
            anchor: vertex,
            control: vertex,
            internal_vertices: []
          }
        end

        # Combine results (at least forward must exist)
        return nil unless result_forward && result_backward

        # Forward direction gives us P2 (anchor) and P3 (control)
        # Backward direction gives us P1 (anchor) and P0 (control)
        {
          P0: result_backward[:control],
          P1: result_backward[:anchor],
          P2: result_forward[:anchor],
          P3: result_forward[:control],
          internal_vertices: result_forward[:internal_vertices] + [vertex] + result_backward[:internal_vertices]
        }
      end

      # Extracts all unique vertices from a list of edges
      #
      # @param edges [Array<Sketchup::Edge>] Edges to extract vertices from
      # @return [Set<Sketchup::Vertex>] Set of unique vertices
      def self.extract_vertices_from_edges(edges)
        vertices = Set.new
        edges.each do |edge|
          vertices.add(edge.start)
          vertices.add(edge.end)
        end
        vertices
      end

      # Finds an edge connected to vertex that is NOT in the selected edges
      # (orthogonal to the column direction)
      #
      # @param vertex [Sketchup::Vertex] Vertex to search from
      # @param selected_edges [Array<Sketchup::Edge>] Selected edges
      # @return [Sketchup::Edge, nil] Orthogonal edge or nil if not found
      def self.find_orthogonal_edge(vertex, selected_edges)
        vertex.edges.each do |edge|
          return edge unless selected_edges.include?(edge)
        end
        nil
      end

      # Traverses the mesh in a given direction, collecting selected vertices
      # until reaching a non-selected vertex (anchor) and continuing one more step (control)
      #
      # @param start_vertex [Sketchup::Vertex] Starting vertex
      # @param start_edge [Sketchup::Edge, nil] Initial edge in direction (can be nil)
      # @param direction [Geom::Vector3d] Direction vector to follow
      # @param selected_vertices_set [Set<Sketchup::Vertex>] Set of selected vertices
      # @param selected_edges [Array<Sketchup::Edge>] Selected edges
      # @return [Hash, nil] Hash with :anchor, :control, :internal_vertices
      def self.traverse_direction(start_vertex, start_edge, direction, selected_vertices_set, selected_edges)
        return nil unless start_edge

        internal_vertices = []
        current_vertex = start_edge.other_vertex(start_vertex)
        current_edge = start_edge

        # Collect consecutive selected vertices
        while selected_vertices_set.include?(current_vertex)
          internal_vertices << current_vertex

          # Find next edge in same direction
          next_edge = find_continuation_edge(current_vertex, current_edge, direction, selected_edges)
          break unless next_edge

          current_vertex = next_edge.other_vertex(current_vertex)
          current_edge = next_edge
        end

        # Current vertex is now the first NON-selected vertex → this is our anchor
        anchor_vertex = current_vertex

        # Continue one more step to find control point
        control_edge = find_continuation_edge(anchor_vertex, current_edge, direction, selected_edges)
        control_vertex = control_edge ? control_edge.other_vertex(anchor_vertex) : nil

        # If no control vertex found, use anchor as control (boundary case)
        control_vertex ||= anchor_vertex

        {
          anchor: anchor_vertex,
          control: control_vertex,
          internal_vertices: internal_vertices
        }
      end

      # Finds the edge that best continues in the given direction from a vertex
      # Uses dot product to find edge most aligned with direction vector
      #
      # @param vertex [Sketchup::Vertex] Current vertex
      # @param previous_edge [Sketchup::Edge, nil] Edge we came from (to exclude)
      # @param direction [Geom::Vector3d] Direction to continue in
      # @param selected_edges [Array<Sketchup::Edge>] Selected edges (to exclude)
      # @return [Sketchup::Edge, nil] Best continuation edge
      def self.find_continuation_edge(vertex, previous_edge, direction, selected_edges)
        best_edge = nil
        best_dot = -2.0  # Impossible value (dot ∈ [-1, 1])

        vertex.edges.each do |edge|
          # Skip the edge we came from
          next if edge == previous_edge

          # Skip selected edges (we only traverse via non-selected edges)
          next if selected_edges.include?(edge)

          # Calculate direction vector of this edge
          other_vertex = edge.other_vertex(vertex)
          edge_direction = (other_vertex.position - vertex.position).normalize

          # Measure alignment with desired direction
          dot = direction.dot(edge_direction)

          # Update best if this is more aligned
          if dot > best_dot
            best_dot = dot
            best_edge = edge
          end
        end

        # Return best edge only if reasonably aligned (threshold ~60°)
        best_dot > 0.5 ? best_edge : nil
      end

      # Checks if an edge is part of the selection
      #
      # @param edge [Sketchup::Edge] Edge to check
      # @param selected_edges [Array<Sketchup::Edge>] Selected edges
      # @return [Boolean] True if edge is selected
      def self.is_edge_selected?(edge, selected_edges)
        selected_edges.include?(edge)
      end
    end
  end
end
