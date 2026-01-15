# frozen_string_literal: true

#==============================================================================
# CurvyQuads - Set Flow Tool
#==============================================================================
# Tool: Set Flow
# Purpose: Conform edge loops to adjacent curvature using Hermite spline interpolation
# Algorithm: Industry-standard per-vertex Hermite spline (alternative to Catmull-Rom)

# Algorithm Overview:
# 1. For each vertex V in selected loop:
#    a. Find ring control points: P0, P1 (V's neighbors), P2, P3 (second-order)
#       CRITICAL: Control points must be in sequential order along ring!
#    b. Calculate Hermite spline at t=0.5 using tangent vectors
#    c. Displacement = Target - V_original
# 2. Batch transform all vertices simultaneously (prevents coordinate corruption)
# 3. Apply intensity scaling (0% = no movement, 100% = full, 200% = overshoot)

# Topology Navigation Credits:
# Thomas Thomassen (QuadFace Tools) - Pure topological methods
#==============================================================================

module MarcelloPanicciaTools
  module CurvyQuads
    module Tools
      module SetFlowTool
        extend self

        TOOL_NAME = 'Set Flow'
        PREF_KEY = 'MarcelloPanicciaTools_CurvyQuads_SetFlow'

        # State variables
        @model = nil
        @selection = nil
        @entities = nil
        @dialog = nil
        @tracker = nil
        @operation_started = false
        @transform_map = {}
        @original_positions = {}
        @uv_session = nil
        @last_intensity = 1.0
        @preserve_uv = false

        #======================================================================
        # ACTIVATION & CLEANUP
        #======================================================================

        def activate
          @model = Sketchup.active_model
          @selection = @model.selection
          @entities = @model.active_entities

          unless Shared::ToolManager.activate_tool(TOOL_NAME, self)
            return
          end

          unless validate_edit_context
            Shared::ToolManager.deactivate_tool(TOOL_NAME)
            return
          end

          setup_selection_tracking
          create_dialog
          refresh_geometry_session
        end

        def validate_edit_context
          if @model.active_path.nil?
            UI.messagebox(
              "Set Flow requires editing inside a Group or Component.\n\n" \
              "Please:\n" \
              "1. Double-click a Group/Component to enter edit mode\n" \
              "2. Run Set Flow again",
              MB_OK
            )
            return false
          end
          true
        end

        def setup_selection_tracking
          @tracker = Shared::SelectionTracker.start_tracking(@model) do
            refresh_geometry_session
          end
        end

        def create_dialog
          @dialog = SetFlowDialog.new(self)
          @dialog.create_dialog
        end

        def cleanup
          @tracker.stop if @tracker
          @tracker = nil
          @dialog.close_dialog if @dialog
          @dialog = nil
          Shared::ToolManager.deactivate_tool(TOOL_NAME)
          @operation_started = false
          @transform_map = {}
          @original_positions = {}
          @uv_session = nil
        end

        #======================================================================
        # SELECTION PROCESSING
        #======================================================================

        def refresh_geometry_session
          return unless @tracker
          @tracker.processing = true

          if @operation_started
            @model.abort_operation
            @operation_started = false
          end

          if selection_contains_groups?
            Sketchup.set_status_text("Set Flow: Invalid selection (Groups/Components not allowed)")
            @tracker.processing = false
            return
          end

          raw_edges = @selection.grep(Sketchup::Edge)
          if raw_edges.empty?
            Sketchup.set_status_text("Set Flow: Select edges to begin...")
            @tracker.processing = false
            return
          end

          @model.start_operation(TOOL_NAME, false)
          @operation_started = true

          begin
            Sketchup.set_status_text("Set Flow: Calculating topology...")
            Shared::GeometryUtils.mp3d_cq_triangulate_faces(@entities, nil)

            if calculate_topology_data(raw_edges)
              all_verts = @transform_map.keys
              @uv_session = Shared::UVHelper::UVSession.new(all_verts)
              apply_transform(@last_intensity)
              Sketchup.set_status_text("Set Flow: Ready. Adjust intensity or confirm.")
            else
              Sketchup.set_status_text("Set Flow: No valid flow vertices found.")
            end
          rescue => e
            puts "[Set Flow] Error: #{e.message}"
            puts e.backtrace.join("\n")
            @model.abort_operation
            @operation_started = false
          end

          @tracker.processing = false
        end

        #======================================================================
        # HERMITE SPLINE ALGORITHM (Core Logic)
        #======================================================================

        def calculate_topology_data(edges)
          @transform_map = {}
          @original_positions = {}

          edges.each do |e|
            e.vertices.each do |v|
              @original_positions[v] ||= v.position.clone
            end
          end

          loops = Shared::TopologyAnalyzer.detect_loops(edges)
          puts "[Set Flow] Detected #{loops.size} loop(s)"
          return false if loops.empty?

          loops.each_with_index do |loop, idx|
            puts "[Set Flow] Processing loop #{idx + 1}/#{loops.size}"
            process_loop_hermite(loop)
          end

          puts "[Set Flow] Total vertices with displacements: #{@transform_map.size}"
          !@transform_map.empty?
        end

        def process_loop_hermite(loop)
          loop_vertices = []
          loop.each do |edge|
            edge.vertices.each do |v|
              loop_vertices << v unless loop_vertices.include?(v)
            end
          end

          processed = 0
          skipped = 0

          loop_vertices.each do |vertex|
            next if @transform_map.key?(vertex)

            if is_boundary_vertex?(vertex)
              skipped += 1
              next
            end

            # Find loop edge at this vertex for directional reference
            loop_edge = loop.find { |e| e.vertices.include?(vertex) }
            unless loop_edge
              skipped += 1
              next
            end

            ring_edges = vertex.edges.reject { |e| loop.include?(e) }
            ring_edges.reject! { |e| Shared::TopologyAnalyzer.is_qft_diagonal?(e) }

            unless ring_edges.size == 2
              skipped += 1
              next
            end

            # FIX (2026-01-12): Order ring_edges DETERMINISTICALLY using robust geometric method
            # BEFORE topological navigation. This ensures P1/P2 are consistently oriented.
            ordered_ring_edges = order_ring_edges_by_signed_angle(vertex, loop_edge, ring_edges)

            # Use ROBUST topological navigation
            control_points = find_control_points_topology(
              vertex,
              ordered_ring_edges,
              loop
            )

            unless control_points
              skipped += 1
              next
            end

            # Fail gracefully if topology is broken
            next if control_points[:p0].nil? || control_points[:p1].nil? ||
                    control_points[:p2].nil? || control_points[:p3].nil?

            # Use Hermite spline
            target = calculate_hermite_point(
              control_points[:p0],
              control_points[:p1],
              control_points[:p2],
              control_points[:p3]
            )

            original = @original_positions[vertex]
            displacement = target - original

            if displacement.length > 1.0e-5
              @transform_map[vertex] = displacement
              processed += 1
            end
          end

          puts "[Set Flow] Loop: #{processed} processed, #{skipped} skipped"
        end

        # Order ring edges by SIGNED ANGLE relative to loop direction.
        # This is the ONLY mathematically rigorous way to establish consistent L/R orientation.
        #
        # ALGORITHM:
        # 1. Get loop direction vector at V
        # 2. Get surface normal (average of adjacent face normals)
        # 3. Create orthonormal basis: (loop_dir, perpendicular, normal)
        # 4. Project each ring edge onto the perpendicular plane
        # 5. Calculate signed angle using atan2
        # 6. Sort by angle: smaller angle = "left", larger = "right"
        #
        # WHY THIS WORKS:
        # - Signed angle is invariant under loop orientation
        # - Works on ANY surface orientation (vertical, horizontal, oblique)
        # - Deterministic: same vertex always gives same order
        #
        # @param vertex [Sketchup::Vertex] Current vertex
        # @param loop_edge [Sketchup::Edge] Edge from loop (defines "forward")
        # @param ring_edges [Array<Sketchup::Edge>] Two ring edges to order
        # @return [Array<Sketchup::Edge>] Ordered [left_edge, right_edge]
        #
        def order_ring_edges_by_signed_angle(vertex, loop_edge, ring_edges)
          return ring_edges if ring_edges.size != 2

          v_pos = vertex.position

          # Step 1: Loop direction
          loop_dir = (loop_edge.other_vertex(vertex).position - v_pos)
          return ring_edges if loop_dir.length < 0.001
          loop_dir.normalize!

          # Step 2: Surface normal (robust average)
          normal = Geom::Vector3d.new(0, 0, 0)
          loop_edge.faces.each { |f| normal = normal + f.normal }
          return ring_edges if normal.length < 0.001
          normal.normalize!

          # Step 3: Perpendicular direction (in plane of surface, perpendicular to loop)
          # perpendicular = normal × loop_dir (right-handed system)
          perp = normal.cross(loop_dir)
          return ring_edges if perp.length < 0.001
          perp.normalize!

          # Step 4 & 5: Calculate signed angle for each ring edge
          angles = ring_edges.map do |edge|
            edge_dir = (edge.other_vertex(vertex).position - v_pos)
            edge_dir.normalize! if edge_dir.length > 0.001

            # Project onto (loop_dir, perp) plane and get signed angle
            x_component = edge_dir % loop_dir  # dot product
            y_component = edge_dir % perp      # dot product
            angle = Math.atan2(y_component, x_component)

            { edge: edge, angle: angle }
          end

          # Step 6: Sort by angle (smaller angle first = "left")
          sorted = angles.sort_by { |item| item[:angle] }
          [sorted[0][:edge], sorted[1][:edge]]
        end

        # Find 4 control points using pure topological navigation.
        # Assumes ring_edges are PRE-ORDERED by order_ring_edges_by_signed_angle.
        #
        # @param vertex [Sketchup::Vertex] Current vertex (V)
        # @param ring_edges [Array] Two ring edges (PRE-ORDERED)
        # @param loop [Array] Full loop for validation
        # @return [Hash, nil] {p0:, p1:, p2:, p3:} or nil if topology invalid
        #
        def find_control_points_topology(vertex, ring_edges, loop)
          v_pos = vertex.position

          ring_edge_1 = ring_edges[0]
          ring_edge_2 = ring_edges[1]

          # Walk Direction 1: V → P1 → P0
          side_1_first = navigate_ring_step(vertex, ring_edge_1, loop)
          return nil unless side_1_first
          side_1_second = navigate_ring_step(side_1_first[:vertex], side_1_first[:edge], loop)

          # Walk Direction 2: V → P2 → P3
          side_2_first = navigate_ring_step(vertex, ring_edge_2, loop)
          return nil unless side_2_first
          side_2_second = navigate_ring_step(side_2_first[:vertex], side_2_first[:edge], loop)

          # Extract positions
          p1_candidate = side_1_first[:vertex].position
          p2_candidate = side_2_first[:vertex].position

          # Handle P0: check for closed ring (cylinder case)
          if side_1_second && side_1_second[:vertex] == vertex
            # Closed ring detected
            v_ring_edges = vertex.edges.reject { |e| loop.include?(e) || Shared::TopologyAnalyzer.is_qft_diagonal?(e) }
            if v_ring_edges.size == 2
              other_ring_edge = v_ring_edges.find { |e| e != ring_edge_1 }
              p0_candidate = other_ring_edge ? other_ring_edge.other_vertex(vertex).position : extrapolate_phantom(p1_candidate, v_pos, outward: false)
            else
              p0_candidate = extrapolate_phantom(p1_candidate, v_pos, outward: false)
            end
          elsif side_1_second
            p0_candidate = side_1_second[:vertex].position
          else
            p0_candidate = extrapolate_phantom(p1_candidate, v_pos, outward: false)
          end

          # Handle P3: check for closed ring (cylinder case)
          if side_2_second && side_2_second[:vertex] == vertex
            # Closed ring detected
            step_from_p2 = navigate_ring_step(side_2_first[:vertex], side_2_first[:edge], loop)
            p3_candidate = step_from_p2 ? step_from_p2[:vertex].position : extrapolate_phantom(p2_candidate, v_pos, outward: true)
          elsif side_2_second
            p3_candidate = side_2_second[:vertex].position
          else
            p3_candidate = extrapolate_phantom(p2_candidate, v_pos, outward: true)
          end

          {
            p0: p0_candidate,
            p1: p1_candidate,
            p2: p2_candidate,
            p3: p3_candidate
          }
        end

        def navigate_ring_step(start_vertex, ring_edge, loop)
          next_vertex = ring_edge.other_vertex(start_vertex)
          quad_edges = next_vertex.edges.reject { |e| Shared::TopologyAnalyzer.is_qft_diagonal?(e) }
          return nil unless quad_edges.size == 4

          opposite_edge = Shared::TopologyAnalyzer.find_topology_opposite_edge(ring_edge, quad_edges)
          return nil unless opposite_edge
          return nil if loop.include?(opposite_edge)

          {
            vertex: next_vertex,
            edge: opposite_edge
          }
        end

        def extrapolate_phantom(neighbor_pos, vertex_pos, outward:)
          vec = neighbor_pos - vertex_pos
          if outward
            neighbor_pos + vec
          else
            vertex_pos - vec
          end
        end

        # Calculate Hermite spline interpolation point at t=0.5.
        #
        # HERMITE SPLINE FORMULA:
        # Given two points P1, P2 and their tangent vectors T1, T2:
        # H(t) = (2t³ - 3t² + 1)P1 + (-2t³ + 3t²)P2 + (t³ - 2t² + t)T1 + (t³ - t²)T2
        #
        # At t=0.5 (simplified):
        # H(0.5) = 0.5P1 + 0.5P2 + 0.125T1 - 0.125T2
        #
        # Tangent calculation:
        # T1 = (P2 - P0) / 2 (tangent at P1 based on neighboring points)
        # T2 = (P3 - P1) / 2 (tangent at P2 based on neighboring points)
        #
        # This approach is more robust than Catmull-Rom when control points
        # may not be perfectly ordered, as tangents naturally average out errors.
        #
        # @param p0 [Geom::Point3d] Control point 0 (used for tangent calculation)
        # @param p1 [Geom::Point3d] Control point 1 (left neighbor of V)
        # @param p2 [Geom::Point3d] Control point 2 (right neighbor of V)
        # @param p3 [Geom::Point3d] Control point 3 (used for tangent calculation)
        # @return [Geom::Point3d] Target position on the Hermite spline
        #
        def calculate_hermite_point(p0, p1, p2, p3)
          # Calculate tangent vectors
          # T1 = (P2 - P0) / 2
          t1_x = (p2.x - p0.x) * 0.5
          t1_y = (p2.y - p0.y) * 0.5
          t1_z = (p2.z - p0.z) * 0.5

          # T2 = (P3 - P1) / 2
          t2_x = (p3.x - p1.x) * 0.5
          t2_y = (p3.y - p1.y) * 0.5
          t2_z = (p3.z - p1.z) * 0.5

          # Hermite basis functions at t=0.5:
          # h1(0.5) = 2(0.5)³ - 3(0.5)² + 1 = 0.5
          # h2(0.5) = -2(0.5)³ + 3(0.5)² = 0.5
          # h3(0.5) = (0.5)³ - 2(0.5)² + 0.5 = 0.125
          # h4(0.5) = (0.5)³ - (0.5)² = -0.125

          # H(0.5) = 0.5*P1 + 0.5*P2 + 0.125*T1 - 0.125*T2
          target_x = 0.5 * p1.x + 0.5 * p2.x + 0.125 * t1_x - 0.125 * t2_x
          target_y = 0.5 * p1.y + 0.5 * p2.y + 0.125 * t1_y - 0.125 * t2_y
          target_z = 0.5 * p1.z + 0.5 * p2.z + 0.125 * t1_z - 0.125 * t2_z

          Geom::Point3d.new(target_x, target_y, target_z)
        end

        def is_boundary_vertex?(vertex)
          vertex.edges.any? { |e| e.faces.size == 1 }
        end

        def selection_contains_groups?
          @selection.any? do |e|
            e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          end
        end

        #======================================================================
        # TRANSFORMATION (Batch Application)
        #======================================================================

        def apply_transform(intensity)
          return if @transform_map.empty?

          verts = []
          vecs = []

          @transform_map.each do |vertex, displacement|
            next unless vertex.valid?
            original = @original_positions[vertex]

            scaled_displacement = Geom::Vector3d.new(
              displacement.x * intensity,
              displacement.y * intensity,
              displacement.z * intensity
            )

            target = original.offset(scaled_displacement)
            current = vertex.position
            vec = target - current

            if vec.length > 1.0e-5
              verts << vertex
              vecs << vec
            end
          end

          @entities.transform_by_vectors(verts, vecs) unless verts.empty?
          @model.active_view.invalidate
        end

        #======================================================================
        # DIALOG CALLBACKS
        #======================================================================

        def on_preview(params)
          intensity = params['intensity'].to_f / 100.0
          @last_intensity = intensity
          @preserve_uv = params['preserve_uv']
          apply_transform(intensity)
        end

        def on_update(params)
          intensity = params['intensity'].to_f / 100.0
          @last_intensity = intensity
          @preserve_uv = params['preserve_uv']
          apply_transform(intensity)

          if @preserve_uv && @uv_session
            @uv_session.restore(true)
          end
        end

        def on_apply(params)
          intensity = params['intensity'].to_f / 100.0
          @preserve_uv = params['preserve_uv']
          apply_transform(intensity)

          if @preserve_uv && @uv_session
            @uv_session.restore(true)
          end

          if @operation_started
            @model.commit_operation
            @operation_started = false
          end

          cleanup
        end

        def on_cancel
          if @operation_started
            @model.abort_operation
            @operation_started = false
          end
          cleanup
        end

      end # module SetFlowTool

      #========================================================================
      # DIALOG
      #========================================================================

      class SetFlowDialog < Shared::DialogBase
        def initialize(tool)
          @tool = tool
          super('Set Flow', SetFlowTool::PREF_KEY)
        end

        def control_config
          [
            {
              type: :slider,
              id: 'intensity',
              label: 'Flow Intensity',
              min: 0,
              max: 200,
              default: 100
            },
            {
              type: :checkbox,
              id: 'preserve_uv',
              label: 'Preserve UV Coordinates',
              default: false
            }
          ]
        end

        def on_preview(params)
          @tool.on_preview(params)
        end

        def on_update(params)
          @tool.on_update(params)
        end

        def on_apply(params)
          @tool.on_apply(params)
        end

        def on_cancel
          @tool.on_cancel
        end

        def on_dialog_closed
          @tool.on_cancel
        end
      end # class SetFlowDialog

    end # module Tools
  end # module CurvyQuads
end # module MarcelloPanicciaTools
