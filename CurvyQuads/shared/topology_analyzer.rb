# frozen_string_literal: true

#==============================================================================
# CurvyQuads Suite for SketchUp
# File: topology_analyzer.rb
# Version: 1.0.0
# Date: January 2026
# Author: Marcello Paniccia
#
# DESCRIPTION:
#   Provides topology analysis and navigation methods for quad-based meshes
#   in SketchUp. This module implements ring/loop detection and edge
#   navigation algorithms following the QuadFace Tools convention established
#   by Thomas Thomassen.
#
# CREDITS:
#   Quad topology navigation logic inspired by Thomas Thomassen's QuadFace Tools
#   https://github.com/thomthom/quadface-tools
#   Used with permission under open-source license.
#
# OPTIMIZATION NOTE:
#   Unlike the original QuadFace Tools implementation (which handles both
#   native planar quads and triangulated quads), this module assumes that
#   ALL geometry has been pre-triangulated for stability reasons.
#   
#   This allows significant performance optimizations by:
#     - Eliminating conditional checks for native vs triangulated quads
#     - Operating exclusively on triangular faces (face.vertices.size == 3)
#     - Fast-path algorithms optimized for pre-triangulated topology
#   
#   Pre-triangulation is applied as the FIRST step of all CurvyQuads tools
#   to stabilize vertex order, preserve UV coordinates, and ensure predictable
#   behavior across all operations.
#
# QUADFACE TOOLS CONVENTION:
#   A quad is defined as either:
#     1. A native planar quad (4 vertices, single face) [NOT in our workflow]
#     2. Two triangles separated by a QFT-compliant diagonal edge
#   
#   A QFT diagonal edge is identified by:
#     - edge.soft? == true
#     - edge.smooth? == true
#     - edge.casts_shadows? == false
#   
#   This convention allows SketchUp to represent non-planar quads using
#   triangulated geometry while maintaining quad topology semantics.
#==============================================================================

# frozen_string_literal: true

#==============================================================================
# CurvyQuads - Topology Analyzer Module
#==============================================================================
# Module: TopologyAnalyzer
# Purpose: QuadFace Tools (QFT) convention topology detection and navigation
#
# This module implements the QuadFace Tools diagonal convention created by
# Thomas Thomassen (ThomThom). It provides robust loop/ring detection for
# quad mesh topology analysis.
#
# QuadFace Tools Convention (QFT):
# ---------------------------------
# A "diagonal" edge in QFT is identified by ALL THREE properties:
#   1. edge.soft? == true
#   2. edge.smooth? == true  
#   3. edge.casts_shadows? == false
#
# The casts_shadows property is used as a "flag" since SketchUp has no
# native API for non-planar quad faces. This convention allows quad meshes
# to be stored as triangulated geometry while preserving topological intent.
#
# Key Algorithms:
# ---------------
# - detect_loops: Find continuous edge sequences (closed or open)
# - walk_ring: Navigate perpendicular to edge direction (across quads)
# - is_valid_ring_vertex: Check if vertex supports ring navigation
# - find_topology_opposite_edge: Pure topological opposite edge in quad
#
# PDF Reference: Section 3 (QuadFace Tools Convention)
#==============================================================================

module MarcelloPanicciaTools
  module CurvyQuads
    module Shared
      module TopologyAnalyzer
        extend self

        #======================================================================
        # QFT DIAGONAL DETECTION
        #======================================================================

        # Check if edge is a QFT diagonal.
        #
        # A diagonal must have ALL THREE properties:
        # - soft (curves smoothly)
        # - smooth (no hard visual edge)
        # - casts_shadows == false (QFT flag)
        #
        # @param edge [Sketchup::Edge] Edge to check
        # @return [Boolean] true if edge is QFT diagonal
        #
        # @example
        #   if TopologyAnalyzer.is_qft_diagonal?(edge)
        #     puts "This is a diagonal, skip it"
        #   end
        #
        def is_qft_diagonal?(edge)
          edge.soft? && edge.smooth? && !edge.casts_shadows?
        end

        # Check if two triangular faces form a valid QFT quad.
        #
        # Valid quad requirements:
        # - Both faces are triangles (3 vertices each)
        # - Share exactly one edge
        # - Shared edge is QFT diagonal
        #
        # @param face1 [Sketchup::Face] First face
        # @param face2 [Sketchup::Face] Second face
        # @return [Boolean] true if faces form valid QFT quad
        #
        def is_part_of_qft_quad?(face1, face2)
          return false unless face1.vertices.size == 3 && face2.vertices.size == 3
          
          shared_edges = face1.edges & face2.edges
          return false unless shared_edges.size == 1
          
          is_qft_diagonal?(shared_edges.first)
        end

        #======================================================================
        # LOOP DETECTION
        #======================================================================

        # Detect closed or open edge loops from a selection of edges.
        #
        # This method groups connected edges into continuous chains (loops).
        # A loop is "closed" if it forms a ring (start == end), otherwise it's "open".
        # Used for topology analysis in Set Flow and Regularize operations.
        #
        # @param edges [Array<Sketchup::Edge>] The edges to analyze
        # @return [Array<Array<Sketchup::Edge>>] Array of loops (each loop is array of edges)
        # @return [Array] Empty array if no valid loops found
        #
        # @example
        #   edges = model.selection.grep(Sketchup::Edge)
        #   loops = TopologyAnalyzer.detect_loops(edges)
        #   loops.each { |loop| puts "Loop has #{loop.size} edges" }
        #
        # @note This algorithm uses a "grow forward/backward" approach:
        #   1. Filter out diagonal edges (Issue #4 FIX)
        #   2. Pick a seed edge from remaining quad borders
        #   3. Grow forward from end vertex
        #   4. Grow backward from start vertex
        #   5. Combine into single loop
        #   6. Detect if closed (start == end)
        #
        def detect_loops(edges)
          return [] if edges.empty?

          # Issue #4 FIX: Filter out QFT diagonal edges before processing
          # Only process quad border edges (non-diagonals)
          quad_borders = edges.reject { |e| is_qft_diagonal?(e) }
          return [] if quad_borders.empty?

          loops = []
          visited = {}

          quad_borders.each do |seed_edge|
            next if visited[seed_edge]

            # Grow loop forward from seed end vertex
            forward_chain = grow_loop_forward(seed_edge, quad_borders, visited)
            
            # Grow loop backward from seed start vertex
            backward_chain = grow_loop_backward(seed_edge, quad_borders, visited)
            
            # Combine: backward (reversed) + seed + forward
            full_loop = backward_chain.reverse + [seed_edge] + forward_chain
            
            # Mark all edges as visited
            full_loop.each { |e| visited[e] = true }
            
            loops << full_loop
          end

          loops
        end

        # Grow loop forward from an edge's end vertex.
        #
        # Continues adding edges until:
        # - No more connected edges found
        # - Hit a visited edge (loop closure)
        # - Hit a pole (vertex with valence != 4)
        # - Hit a boundary edge
        #
        # @param seed_edge [Sketchup::Edge] Starting edge
        # @param available_edges [Array<Sketchup::Edge>] Pool of edges to use
        # @param visited [Hash] Tracking hash of visited edges
        # @return [Array<Sketchup::Edge>] Forward chain (may be empty)
        #
        # @note This is a private helper for detect_loops
        #
        def grow_loop_forward(seed_edge, available_edges, visited)
          chain = []
          current_edge = seed_edge
          current_vertex = seed_edge.end

          loop do
            next_edge = find_next_loop_edge(current_vertex, current_edge, available_edges)
            break if next_edge.nil? || visited[next_edge]

            chain << next_edge
            visited[next_edge] = true

            # Move to next vertex (the one that's NOT current_vertex)
            current_vertex = (next_edge.start == current_vertex) ? next_edge.end : next_edge.start
            current_edge = next_edge
          end

          chain
        end

        # Grow loop backward from an edge's start vertex.
        #
        # Same logic as grow_loop_forward but in opposite direction.
        #
        # @param seed_edge [Sketchup::Edge] Starting edge
        # @param available_edges [Array<Sketchup::Edge>] Pool of edges to use
        # @param visited [Hash] Tracking hash of visited edges
        # @return [Array<Sketchup::Edge>] Backward chain (may be empty)
        #
        def grow_loop_backward(seed_edge, available_edges, visited)
          chain = []
          current_edge = seed_edge
          current_vertex = seed_edge.start

          loop do
            next_edge = find_next_loop_edge(current_vertex, current_edge, available_edges)
            break if next_edge.nil? || visited[next_edge]

            chain << next_edge
            visited[next_edge] = true

            # Move to next vertex
            current_vertex = (next_edge.start == current_vertex) ? next_edge.end : next_edge.start
            current_edge = next_edge
          end

          chain
        end

        # Find next edge in loop from current vertex.
        #
        # Rules:
        # - Must be connected to current_vertex
        # - Must NOT be current_edge (no backtrack)
        # - Must NOT be a diagonal
        # - Prefer edges with same face count as current (maintain manifold)
        #
        # @param vertex [Sketchup::Vertex] Current vertex
        # @param current_edge [Sketchup::Edge] Edge we came from
        # @param available_edges [Array<Sketchup::Edge>] Pool to search
        # @return [Sketchup::Edge, nil] Next edge or nil if none found
        #
        def find_next_loop_edge(vertex, current_edge, available_edges)
          candidates = vertex.edges & available_edges
          candidates.delete(current_edge) # Don't go backward
          candidates.reject! { |e| is_qft_diagonal?(e) } # Skip diagonals

          return nil if candidates.empty?

          # Prefer edges with same face count (maintains manifold topology)
          current_face_count = current_edge.faces.size
          same_count = candidates.select { |e| e.faces.size == current_face_count }
          
          same_count.empty? ? candidates.first : same_count.first
        end

        #======================================================================
        # RING NAVIGATION (Perpendicular Walk)
        #======================================================================

        # Walk across quad ring (perpendicular to edge direction).
        #
        # Given an edge in a quad mesh, find the opposite edge in the
        # adjacent quad by:
        # 1. Identify the two quads sharing this edge
        # 2. Find topologically opposite edge in each quad
        # 3. Return the one that's NOT in the same face
        #
        # @param edge [Sketchup::Edge] Starting edge
        # @param loop_edges [Array<Sketchup::Edge>] Context edges (for opposite detection)
        # @return [Sketchup::Edge, nil] Opposite edge or nil if not found
        #
        # @example
        #   # Walk perpendicular across quad strip
        #   current = start_edge
        #   5.times do
        #     current = TopologyAnalyzer.walk_ring(current, loop_edges)
        #     break if current.nil?
        #   end
        #
        def walk_ring(edge, loop_edges)
          edge.vertices.each do |vertex|
            next unless is_valid_ring_vertex?(vertex, edge)

            opposite = find_topology_opposite_edge(edge, vertex.edges & loop_edges)
            return opposite if opposite && opposite != edge
          end

          nil
        end

        # Check if vertex is valid for ring navigation.
        #
        # Valid ring vertex requirements:
        # - Valence == 4 (exactly 4 quad borders meet)
        # - NO boundary edges (all edges have 2 faces)
        # - NO non-manifold edges (all edges have <= 2 faces) [Issue #5 FIX]
        #
        # @param vertex [Sketchup::Vertex] Vertex to check
        # @param reference_edge [Sketchup::Edge] Edge we're navigating from
        # @return [Boolean] true if vertex supports ring walk
        #
        # @note Valence counts only quad border edges (excludes diagonals)
        #
        def is_valid_ring_vertex?(vertex, reference_edge)
          quad_borders = vertex.edges.reject { |e| is_qft_diagonal?(e) }
          
          # Check valence == 4 (exactly 4 quad borders)
          return false unless quad_borders.size == 4
          
          # Check no boundary edges (all have 2 faces)
          return false if quad_borders.any? { |e| e.faces.size != 2 }
          
          # Issue #5 FIX: Check no non-manifold edges (faces.size > 2)
          return false if quad_borders.any? { |e| e.faces.size > 2 }
          
          true
        end

        # Find topologically opposite edge in a quad.
        #
        # In a quad with 4 edges [e0, e1, e2, e3], the opposite of:
        # - e0 is e2 (index + 2)
        # - e1 is e3 (index + 2)
        #
        # @param edge [Sketchup::Edge] Reference edge
        # @param quad_edges [Array<Sketchup::Edge>] All 4 edges of quad (no diagonals)
        # @return [Sketchup::Edge, nil] Opposite edge or nil if not found
        #
        # @note Assumes quad_edges contains exactly 4 edges
        #
        def find_topology_opposite_edge(edge, quad_edges)
          return nil unless quad_edges.size == 4
          
          index = quad_edges.index(edge)
          return nil if index.nil?
          
          opposite_index = (index + 2) % 4
          quad_edges[opposite_index]
        end

        #======================================================================
        # UTILITY METHODS
        #======================================================================

        # Get all quad borders (non-diagonal edges) from a face.
        #
        # @param face [Sketchup::Face] Face to analyze
        # @return [Array<Sketchup::Edge>] Non-diagonal edges
        #
        def get_quad_borders(face)
          face.edges.reject { |e| is_qft_diagonal?(e) }
        end

        # Check if face is a valid QFT quad (two triangles).
        #
        # @param face [Sketchup::Face] Face to check
        # @return [Boolean] true if face is part of QFT quad
        #
        def is_qft_quad_face?(face)
          return false unless face.vertices.size == 3
          
          face.edges.any? { |e| is_qft_diagonal?(e) }
        end

        # Get vertex valence (count of non-diagonal edges).
        #
        # @param vertex [Sketchup::Vertex] Vertex to analyze
        # @return [Integer] Number of quad border edges
        #
        def get_vertex_valence(vertex)
          vertex.edges.count { |e| !is_qft_diagonal?(e) }
        end

      end # module TopologyAnalyzer
    end # module Shared
  end # module CurvyQuads
end # module MarcelloPanicciaTools
