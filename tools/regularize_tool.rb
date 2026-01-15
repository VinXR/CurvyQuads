# frozen_string_literal: true

#==============================================================================
# CurvyQuads - Regularize Tool
#==============================================================================
# Tool: Regularize
# Purpose: Transform edge loops into perfect circles using best-fit algorithm
# Algorithm Source: regularize_beta_02_0.rb (VALIDATED - do not modify)
#
# Features:
# - Preselection of edges or faces (or both)
# - Active as SketchUp Tool (exits other tools, cancels on tool switch)
# - Best-fit circle calculation (Newell's method + coordinate system alignment)
# - Intensity slider (0-100%)
# - UV preservation option (using UVSession manager)
# - QFT pre-triangulation (delegated to shared GeometryUtils)
# - Partial selection support (processes valid loops, skips invalid)
# - Deselects invalid clusters before starting
# - Preserves original selection on cancel
# - X button properly aborts without freeze
#
# Workflow:
# 1. Validate preselection (edges and/or faces)
# 2. Filter valid loops, deselect invalid clusters
# 3. Store original selection for restoration on cancel
# 4. Become active tool (exits selection tool)
# 5. Open parametric dialog (using DialogBase)
# 6. User adjusts intensity/UV → live preview
# 7. Apply: finalize transformation, return to selection tool
# 8. Cancel/ESC/X: abort operation, restore original selection, return to selection tool
#
# Selection Logic (from regularize_beta_02_0.rb):
# - User can select mixed edges/faces with both valid and invalid clusters
# - Invalid clusters are deselected visually before tool starts
# - If at least one valid loop exists, tool proceeds
# - Only if ALL clusters are invalid, show error and abort
# - On cancel, original selection is fully restored
#
# UV Preservation (FIXED - Session UV Restore):
# - Uses UVSession manager (shared/uv_helper.rb)
# - UV captured ALWAYS at session start (after triangulation)
#   (Matching spherify_v1_7.rb proven logic)
# - UV restored CONDITIONALLY based on checkbox state:
#   * on_update (slider release): restore if checkbox checked
#   * on_apply (OK button): restore if checkbox checked
#   * on_preview (slider drag): NO restore (performance)
# - This allows user to toggle checkbox mid-operation and see effect
#
# PDF Reference: Section 8A (Regularize Tool)
#==============================================================================

module MarcelloPanicciaTools
module CurvyQuads
module Tools
module RegularizeTool
  extend self

  TOOL_NAME = 'Regularize'
  PREF_KEY = 'CurvyQuads_RegularizeTool'

  # Tool state
  @model = nil
  @selection = nil
  @dialog = nil
  @tool_instance = nil
  @is_active = false
  @operation_started = false

  # Selection tracking (for restoration on cancel)
  @original_selection_ids = []

  # Geometry data
  @edge_loops = []
  @original_positions = {}
  @target_points_per_loop = []

  # UV session manager
  @uv_session = nil

  # Parameters
  @last_intensity = nil
  @last_preserve_uv = nil

  #======================================================================
  # ACTIVATION
  #======================================================================
  
  # Activate Regularize tool.
  #
  # Entry point for tool activation. Validates preselection and starts
  # interactive session if valid.
  #
  # Validation Rules:
  # - Must have at least one edge OR one face selected
  # - Empty selection is invalid (shows error message)
  #
  # Initial Parameter Loading:
  # - Reads user defaults from SettingsManager
  # - If no user defaults, uses factory defaults (1.0, false)
  #
  # @return [void]
  #
  # @example Toolbar button click
  #   RegularizeTool.activate
  #
  def activate
    return if @is_active

    @model = Sketchup.active_model
    @selection = @model.selection

    # Check ToolManager mutex
    unless Shared::ToolManager.activate_tool(TOOL_NAME, self)
      return # Another tool is active, abort
    end

    # Validate preselection (must have at least some edges or faces)
    unless mp3d_cq_validate_selection
      ::UI.messagebox(
        "Regularize requires preselection:\n\n" \
        "• Select edges forming loops\n" \
        "• Or select faces to regularize their boundaries\n" \
        "• Or mix of edges and faces",
        MB_OK
      )
      return
    end

    # Load defaults from Settings (user defaults if set, else factory defaults)
    @last_intensity = Shared::SettingsManager.mp3d_cq_get_parameter('regularize', 'intensity') || 1.0
    @last_preserve_uv = Shared::SettingsManager.mp3d_cq_get_parameter('regularize', 'preserve_uv') || false

    @is_active = true
    @operation_started = false

    # Create tool instance and activate it (exits other tools including selection)
    @tool_instance = RegularizeToolInstance.new(self)
    @model.select_tool(@tool_instance)
  end

  #======================================================================
  # SESSION MANAGEMENT
  #======================================================================
  
  # Start interactive session.
  #
  # Main workflow orchestrator (called by RegularizeToolInstance.activate):
  # 1. Store original selection (for restoration on cancel)
  # 2. Start operation (transparent = can be undone)
  # 3. Pre-triangulate faces (QFT convention - delegated to shared GeometryUtils)
  # 4. Detect edge loops from edges AND faces
  # 5. Sort vertices into ordered loops (skip invalid, keep valid)
  # 6. Deselect invalid clusters (visual cleanup)
  # 7. Cache original positions
  # 8. Initialize UV session (ALWAYS captures UV - matching spherify_v1_7.rb)
  # 9. Calculate target circle positions
  # 10. Apply initial transformation (no UV restore yet)
  # 11. Open parametric dialog
  #
  # Selection Logic (from regularize_beta_02_0.rb):
  # - Process each edge cluster independently
  # - If cluster forms valid closed loop: add to @edge_loops
  # - If cluster is open/invalid: skip silently, deselect from selection
  # - Only abort if NO valid loops found after processing all clusters
  #
  # UV Preservation (FIXED):
  # - UVSession created in Step 8
  # - UV captured AUTOMATICALLY by UVSession constructor (always, not conditional)
  # - This matches spherify_v1_7.rb proven logic (lines 180-188)
  # - Initial transformation (Step 10) does NOT restore UV
  # - UV restored later on slider release and Apply (see dialog callbacks)
  # - User can toggle checkbox mid-operation and see immediate effect
  #
  # @return [void]
  #
  # @note This method is called automatically by SketchUp Tool API
  #   when tool becomes active. Do not call manually.
  #
  def mp3d_cq_start_session
    # Step 1: Store original selection (by entity IDs for restoration)
    @original_selection_ids = @selection.to_a.map(&:entityID)

    # Step 2: Start operation (transparent = can be undone)
    @model.start_operation(TOOL_NAME, true)
    @operation_started = true

    begin
      # Step 3: Pre-triangulate faces (QFT convention)
      # CRITICAL: Must happen BEFORE UV capture
      # Ensures stable vertex order and no autofold during transformation
      # NOW DELEGATED TO SHARED GeometryUtils (Session Spherify)
      mp3d_cq_triangulate_faces

      # Step 4: Detect edge clusters from selection (edges AND faces)
      edge_clusters = mp3d_cq_detect_loops_from_selection

      if edge_clusters.empty?
        ::UI.messagebox("No valid edge loops found.", MB_OK)
        mp3d_cq_abort_and_cleanup
        return
      end

      # Step 5: Sort vertices into ordered loops and collect invalid entities
      # KEY FEATURE: We track which edges belong to invalid clusters
      # so we can deselect them visually
      @edge_loops = []
      invalid_entities = []

      edge_clusters.each do |edges|
        sorted_verts = mp3d_cq_sort_vertices_into_loop(edges)

        if sorted_verts && sorted_verts.size >= 3
          # Valid closed loop with at least 3 vertices
          @edge_loops << sorted_verts
        else
          # Invalid loop: collect all edges and their faces for deselection
          invalid_entities.concat(edges)
          edges.each { |e| invalid_entities.concat(e.faces) }
        end
      end

      # Only abort if NO valid loops found
      if @edge_loops.empty?
        ::UI.messagebox(
          "Found #{edge_clusters.size} edge cluster(s), but none form valid closed loops.\n\n" \
          "Valid loops must:\n" \
          "• Be closed (no endpoints)\n" \
          "• Have exactly 2 edges per vertex (no branching)\n" \
          "• Have at least 3 vertices",
          MB_OK
        )
        mp3d_cq_abort_and_cleanup
        return
      end

      # Step 6: Deselect invalid entities (visual cleanup)
      unless invalid_entities.empty?
        invalid_entities.uniq.each do |entity|
          @selection.remove(entity) if entity.valid?
        end
      end

      # Step 7: Cache original positions
      mp3d_cq_cache_original_positions

      # Step 8: Initialize UV session (FIXED - UV ALWAYS captured)
      # CRITICAL CHANGE: UV data is ALWAYS captured, regardless of
      # @last_preserve_uv checkbox state. This matches spherify_v1_7.rb
      # proven logic (lines 180-188).
      #
      # REASON:
      # User can toggle "Preserve UV" checkbox at ANY time during operation.
      # If we only capture when checkbox initially checked, toggling later
      # has no effect (no UV data to restore).
      #
      # SOLUTION (matching spherify_v1_7.rb):
      # - ALWAYS capture UV at initialization (minimal performance cost)
      # - CONDITIONALLY restore in dialog callbacks based on checkbox state
      # - This allows dynamic checkbox toggling with immediate effect
      #
      # UV capture happens AFTER triangulation (Step 3) - critical for stability
      all_vertices = @original_positions.keys
      @uv_session = Shared::UVHelper::UVSession.new(all_vertices)

      # Step 9: Calculate target circle positions for each valid loop
      mp3d_cq_calculate_target_circles

      # Step 10: Apply initial transformation at current intensity
      # NOTE: UV NOT restored here (will be restored on slider release/Apply)
      mp3d_cq_apply_transformation(@last_intensity)

      # Step 11: Open parametric dialog
      mp3d_cq_create_dialog

      # Optional: Show status message if some clusters were skipped
      if invalid_entities.empty?
        Sketchup.status_text = "#{TOOL_NAME}: Processing #{@edge_loops.size} loop(s)."
      else
        Sketchup.status_text = "#{TOOL_NAME}: Processing #{@edge_loops.size} valid loop(s), deselected invalid clusters."
      end

    rescue => e
      puts "[Regularize] ERROR: #{e.message}"
      puts e.backtrace.join("\n")
      mp3d_cq_abort_and_cleanup
    end
  end

  # Cleanup and restore on cancel/escape/X button.
  #
  # CRITICAL: This method MUST handle all cleanup properly to avoid freeze.
  #
  # Steps:
  # 1. Abort operation (restores geometry to pre-tool state)
  # 2. Restore original selection (fixes "ghost selection" bug)
  # 3. Close dialog (if open)
  # 4. Reset tool state (including UV session)
  # 5. Return to selection tool
  #
  # Called by:
  # - Dialog X button (on_cancel callback)
  # - ESC key (RegularizeToolInstance.onCancel)
  # - Tool deactivation (RegularizeToolInstance.deactivate)
  # - Internal errors (exception handling)
  #
  # @return [void]
  #
  def mp3d_cq_abort_and_cleanup
    # Deregister from ToolManager
    Shared::ToolManager.deactivate_tool(TOOL_NAME)

    # Abort operation (restores geometry) - only if operation was started
    if @operation_started
      begin
        @model.abort_operation
      rescue => e
        puts "[Regularize] Error aborting operation: #{e.message}"
      end
      @operation_started = false
    end

    # Restore original selection (fixes visual deselection bug)
    mp3d_cq_restore_original_selection

    # Close dialog - must set @dialog to nil to prevent recursion
    if @dialog
      begin
        @dialog.close_dialog
      rescue => e
        puts "[Regularize] Error closing dialog: #{e.message}"
      end
      @dialog = nil
    end

    # Reset state (including UV session)
    @is_active = false
    @tool_instance = nil
    @uv_session = nil

    # Return to selection tool (expected behavior)
    begin
      @model.select_tool(nil)
    rescue => e
      puts "[Regularize] Error returning to selection tool: #{e.message}"
    end
  end

  # Finalize on apply.
  #
  # Commits operation (adds to undo stack).
  # Closes dialog and returns to selection tool.
  # Does NOT restore selection (user may want to keep modified geometry selected).
  #
  # Called by:
  # - Dialog Apply/OK button (on_apply callback)
  #
  # @return [void]
  #
  def mp3d_cq_commit_and_cleanup
    # Deregister from ToolManager
    Shared::ToolManager.deactivate_tool(TOOL_NAME)

    # Commit operation (adds to undo stack) - only if operation was started
    if @operation_started
      begin
        @model.commit_operation
      rescue => e
        puts "[Regularize] Error committing operation: #{e.message}"
      end
      @operation_started = false
    end

    # Close dialog
    if @dialog
      begin
        @dialog.close_dialog
      rescue => e
        puts "[Regularize] Error closing dialog: #{e.message}"
      end
      @dialog = nil
    end

    # Reset state (including UV session)
    @is_active = false
    @uv_session = nil

    # Return to selection tool (expected behavior)
    begin
      @model.select_tool(nil)
    rescue => e
      puts "[Regularize] Error returning to selection tool: #{e.message}"
    end
  end

  # Handle tool cancellation (called by ToolManager for automatic closure).
  #
  # When another tool activates while Regularize is active,
  # ToolManager calls this method to close Regularize gracefully.
  #
  # This is identical to dialog Cancel button and ESC key.
  #
  # @return [void]
  #
  def on_cancel
    mp3d_cq_abort_and_cleanup
  end

  #======================================================================
  # SELECTION MANAGEMENT
  #======================================================================
  
  # Validate preselection.
  #
  # Checks that user has selected edges and/or faces.
  # Both types can be mixed.
  # Empty selection is invalid.
  #
  # @return [Boolean] true if valid, false if empty selection
  #
  def mp3d_cq_validate_selection
    edges = @selection.grep(Sketchup::Edge)
    faces = @selection.grep(Sketchup::Face)

    # Must have at least one edge or face
    !edges.empty? || !faces.empty?
  end

  # Restore original selection.
  #
  # Called on cancel to restore selection to pre-tool state.
  # Fixes "ghost selection" bug where faces appear deselected but are still in selection.
  #
  # Algorithm:
  # 1. Clear current selection
  # 2. Find entities by stored entity IDs
  # 3. Re-add them to selection
  #
  # Why This Is Needed:
  # During tool operation, we may deselect invalid clusters.
  # If user cancels, they expect original selection restored.
  #
  # @return [void]
  #
  def mp3d_cq_restore_original_selection
    return if @original_selection_ids.empty?

    begin
      # Clear current selection
      @selection.clear

      # Rebuild selection from stored IDs
      all_entities = @model.active_entities.to_a
      @original_selection_ids.each do |eid|
        entity = all_entities.find { |e| e.entityID == eid }
        @selection.add(entity) if entity && entity.valid?
      end
    rescue => e
      puts "[Regularize] Error restoring selection: #{e.message}"
    end
  end

  #======================================================================
  # TRIANGULATION (Delegated to Shared GeometryUtils - Session Spherify)
  #======================================================================
  
  # Pre-triangulate all faces (QFT convention).
  #
  # Delegates to shared GeometryUtils module (Session Spherify refactoring).
  # See GeometryUtils.mp3d_cq_triangulate_faces for algorithm details.
  #
  # Why This Is Critical:
  # - SketchUp implicitly triangulates non-triangular faces for rendering
  # - Without explicit triangulation, UV capture may fail (vertex order changes)
  # - QFT diagonal convention allows topology_analyzer to detect loops correctly
  # - Pre-triangulation prevents autofold (new edge creation) during transformation
  # - SketchUp can MOVE existing geometry instead of CREATING new geometry
  #
  # @return [void]
  #
  def mp3d_cq_triangulate_faces
    # Collect faces from selection
    faces = @selection.grep(Sketchup::Face)

    # If only edges selected, get their connected faces
    if faces.empty?
      edges = @selection.grep(Sketchup::Edge)
      faces = edges.flat_map(&:faces).uniq
    end

    # Delegate to shared utility (Session Spherify)
    stats = Shared::GeometryUtils.mp3d_cq_triangulate_faces(@model.active_entities, faces)

    # Optional: Log statistics for debugging
    puts "[Regularize] Triangulation: #{stats[:quads]} quads, #{stats[:ngons]} ngons, #{stats[:edges_added]} edges added"
  end

  #======================================================================
  # LOOP DETECTION (From regularize_beta - handles edges AND faces)
  #======================================================================
  
  # Detect edge loops from selection.
  #
  # Uses algorithm from regularize_beta_02_0.rb:
  # - Explicit edges: use directly
  # - Faces: extract boundary edges (edges with only 1 selected face)
  # - Then cluster into connected islands using graph traversal
  #
  # Algorithm:
  # A. Collect explicit edges from selection
  # B. Extract boundary edges from selected faces
  #    (An edge is boundary if only 1 of its faces is selected)
  # C. Cluster connected edges into independent islands
  #
  # @return [Array<Array<Sketchup::Edge>>] Array of edge clusters
  #   Each cluster is an array of connected edges
  #
  def mp3d_cq_detect_loops_from_selection
    edges_to_process = []

    # A. Handle explicitly selected edges
    edges_to_process.concat(@selection.grep(Sketchup::Edge))

    # B. Handle Faces: Extract only the outer perimeter (Border)
    # Logic: A border edge is an edge belonging to a selected face,
    # but NOT shared with another selected face.
    selected_faces = @selection.grep(Sketchup::Face)

    unless selected_faces.empty?
      selected_faces.each do |face|
        face.edges.each do |edge|
          # Check how many faces connected to this edge are currently selected
          selected_neighbor_count = edge.faces.count { |f| @selection.include?(f) }

          # If count is 1, it's a border edge. If > 1, it's internal to selection.
          if selected_neighbor_count == 1
            edges_to_process << edge
          end
        end
      end
    end

    edges_to_process.uniq!

    # C. Cluster connected edges into independent islands
    mp3d_cq_find_connected_clusters(edges_to_process)
  end

  # Group edges into connected islands using graph traversal.
  #
  # Uses depth-first search to find connected components.
  # Each component becomes a separate cluster.
  #
  # Algorithm:
  # 1. For each unvisited edge:
  #    a. Create new cluster
  #    b. Add edge to stack
  #    c. While stack not empty:
  #       - Pop edge
  #       - Mark as visited
  #       - Add to cluster
  #       - Find connected edges (via shared vertices)
  #       - Push unvisited connected edges to stack
  #
  # @param edges [Array<Sketchup::Edge>] Edges to cluster
  # @return [Array<Array<Sketchup::Edge>>] Array of clusters
  #
  def mp3d_cq_find_connected_clusters(edges)
    clusters = []
    visited = {}

    edges.each do |edge|
      next if visited[edge]

      current_cluster = []
      stack = [edge]

      while !stack.empty?
        e = stack.pop
        next if visited[e]

        visited[e] = true
        current_cluster << e

        # Find neighbors (edges connected via shared vertices)
        e.vertices.each do |v|
          v.edges.each do |connected_edge|
            if edges.include?(connected_edge) && !visited[connected_edge]
              stack.push(connected_edge)
            end
          end
        end
      end

      clusters << current_cluster unless current_cluster.empty?
    end

    clusters
  end

  # Sort edges into ordered vertex loop.
  #
  # Uses algorithm from regularize_beta_02_0.rb.
  # Returns nil if loop is open, has branches, or is otherwise invalid.
  #
  # Validation checks:
  # 1. Each vertex must have exactly 2 edges (no branches, no endpoints)
  # 2. Loop must be closed (last vertex connects back to first)
  # 3. Loop must have at least 3 vertices
  #
  # Algorithm:
  # 1. Build vertex => edges mapping
  # 2. Valence check: All vertices must have exactly 2 edges
  # 3. Traverse loop by following edges
  # 4. Check closure: Last vertex must connect back to first
  #
  # @param edges [Array<Sketchup::Edge>] Edges forming loop
  # @return [Array<Sketchup::Vertex>, nil] Ordered vertices or nil if invalid
  #
  def mp3d_cq_sort_vertices_into_loop(edges)
    # Build vertex => edges mapping
    vert_map = Hash.new { |h, k| h[k] = [] }
    edges.each do |e|
      vert_map[e.start] << e
      vert_map[e.end] << e
    end

    # Valence Check: A simple loop must have exactly 2 edges per vertex
    # If any vertex has != 2 edges, loop is open or has branches
    return nil if vert_map.values.any? { |es| es.size != 2 }

    # Traverse loop by following edges
    start_vert = vert_map.keys.first
    ordered = [start_vert]
    current_vert = start_vert
    used_edges = []

    (edges.size - 1).times do
      connected_edges = vert_map[current_vert]
      next_edge = connected_edges.find { |e| !used_edges.include?(e) }

      return nil unless next_edge

      used_edges << next_edge
      next_vert = next_edge.other_vertex(current_vert)
      ordered << next_vert
      current_vert = next_vert
    end

    # Check closure: last vertex must connect back to first vertex
    last_edge_candidates = vert_map[current_vert]
    is_closed = last_edge_candidates.any? do |e|
      e.other_vertex(current_vert) == start_vert && !used_edges.include?(e)
    end

    is_closed ? ordered : nil
  end

  #======================================================================
  # DATA CACHING
  #======================================================================
  
  # Cache original vertex positions.
  #
  # Stores initial positions of all vertices in detected loops.
  # Used for interpolation between original and target positions.
  # Cloned positions ensure they don't change during transformation.
  #
  # Why Clone:
  # If we store vertex.position directly, it's a reference that updates
  # when we transform. We need frozen snapshots for interpolation.
  #
  # @return [void]
  #
  def mp3d_cq_cache_original_positions
    @original_positions = {}

    @edge_loops.each do |loop_verts|
      loop_verts.each do |vertex|
        @original_positions[vertex] ||= vertex.position.clone
      end
    end
  end

  #======================================================================
  # CIRCLE CALCULATION (From regularize_beta_02_0.rb)
  #======================================================================
  
  # Calculate target circle positions for each loop.
  #
  # Uses EXACT algorithm from regularize_beta_02_0.rb:
  # 1. Calculate centroid (geometric center)
  # 2. Calculate average radius (avg distance from centroid)
  # 3. Calculate best-fit normal (Newell's method for robustness)
  # 4. Generate circle points with coordinate system alignment
  #
  # The coordinate system alignment ensures the circle aligns with
  # the first point to minimize twisting/rotation.
  #
  # Algorithm Details:
  # - Centroid: Average of all vertex positions
  # - Radius: Average distance from centroid to each vertex
  # - Normal: Newell's method (robust for non-planar loops)
  # - Circle: Evenly spaced points on plane, rotated to align with first vertex
  #
  # @return [void]
  #
  def mp3d_cq_calculate_target_circles
    @target_points_per_loop = []

    @edge_loops.each do |loop_verts|
      points = loop_verts.map { |v| @original_positions[v] }

      # Geometric calculations
      centroid = Shared::GeometryUtils.mp3d_cq_calculate_centroid(points)
      avg_radius = Shared::GeometryUtils.mp3d_cq_calculate_average_radius(points, centroid)
      normal = Shared::GeometryUtils.mp3d_cq_calculate_best_fit_normal(points)

      # Calculate target circle positions
      target_points = Shared::GeometryUtils.mp3d_cq_calculate_circle_points(
        points.size,
        centroid,
        avg_radius,
        normal,
        points[0]  # First point for alignment (minimizes twist)
      )

      @target_points_per_loop << target_points
    end
  end

  #======================================================================
  # TRANSFORMATION
  #======================================================================
  
  # Apply regularization transformation.
  #
  # For each vertex in each loop:
  # 1. Get target position from pre-calculated circle
  # 2. Interpolate between original and target using intensity parameter
  # 3. Calculate movement vector from current position
  # 4. Apply transformation using transform_by_vectors (batch operation)
  #
  # NOTE: UV restoration is NOT done here.
  # UV is restored separately by dialog callbacks (on_update, on_apply)
  # using @uv_session.restore(preserve_uv_flag)
  #
  # Interpolation Formula:
  #   final_pos = original_pos + (target_pos - original_pos) * intensity
  #
  # Where:
  # - intensity = 0.0: No movement (original shape)
  # - intensity = 1.0: Full regularization (perfect circle)
  # - intensity = 0.5: Halfway between original and circle
  #
  # @param intensity [Float] Intensity (0.0 - 1.0, where 1.0 = perfect circle)
  # @return [void]
  #
  def mp3d_cq_apply_transformation(intensity)
    moves_verts = []
    moves_vecs = []

    @edge_loops.each_with_index do |loop_verts, loop_idx|
      target_points = @target_points_per_loop[loop_idx]

      loop_verts.each_with_index do |vertex, vert_idx|
        next unless vertex.valid?

        original_pos = @original_positions[vertex]
        target_pos = target_points[vert_idx]

        # Calculate movement vector scaled by intensity
        full_movement = target_pos - original_pos
        scaled_movement = Geom::Vector3d.new(
          full_movement.x * intensity,
          full_movement.y * intensity,
          full_movement.z * intensity
        )

        # Calculate final vector from current position to target
        final_vec = (original_pos + scaled_movement) - vertex.position

        # Only move if distance is significant (avoid floating point noise)
        if final_vec.length > 1.0e-5
          moves_verts << vertex
          moves_vecs << final_vec
        end
      end
    end

    # Apply transformation (batch operation for performance)
    unless moves_verts.empty?
      @model.active_entities.transform_by_vectors(moves_verts, moves_vecs)
    end

    # NOTE: UV restoration removed from here
    # UV is now restored by dialog callbacks using @uv_session.restore(flag)
    @model.active_view.invalidate
  end

  #======================================================================
  # DIALOG UI (Using DialogBase)
  #======================================================================
  
  # Create parametric dialog using DialogBase.
  #
  # Dialog provides live preview of intensity changes.
  # User can adjust intensity slider and see results in real-time.
  #
  # @return [void]
  #
  def mp3d_cq_create_dialog
    @dialog = RegularizeDialog.new(self)
    @dialog.create_dialog
  end

  #======================================================================
  # DIALOG CLASS
  #======================================================================
  
  # Dialog class for Regularize (extends DialogBase).
  #
  # Provides:
  # - Intensity slider (0-100%)
  # - Preserve UV checkbox
  # - Reset/Cancel/OK buttons
  #
  # Button Behaviors:
  # - Reset: Restore user defaults from SettingsManager (NOT factory defaults)
  # - Cancel: Abort operation, restore geometry and selection
  # - OK/Apply: Commit operation, add to undo stack
  #
  # UV Restoration Pattern (FIXED):
  # - on_preview: NO UV restore (performance during slider drag)
  # - on_update: YES UV restore IF checkbox checked (slider release)
  # - on_apply: YES UV restore IF checkbox checked (Apply/OK button)
  #
  class RegularizeDialog < Shared::DialogBase
    # Initialize dialog.
    #
    # @param tool [Module] RegularizeTool module
    #
    def initialize(tool)
      super(RegularizeTool::TOOL_NAME, RegularizeTool::PREF_KEY)
      @tool = tool
    end

    # Define control configuration.
    #
    # FIXED (Session #2): Reads user defaults from SettingsManager.
    # Previously used hardcoded default: 100 (factory default).
    # Now reads user's custom default if set in Settings Dialog.
    #
    # Default values shown in dialog:
    # - If user saved custom defaults in Settings Dialog: use those
    # - If no custom defaults: use factory defaults (100%, unchecked)
    #
    # @return [Array<Hash>] Control definitions
    #
    def control_config
      # Read current user defaults from SettingsManager
      # (Returns factory default if user hasn't customized)
      user_intensity = Shared::SettingsManager.mp3d_cq_get_parameter('regularize', 'intensity')
      user_preserve_uv = Shared::SettingsManager.mp3d_cq_get_parameter('regularize', 'preserve_uv')

      # Convert intensity to percentage (stored as 0.0-1.0, displayed as 0-100)
      default_intensity = user_intensity ? (user_intensity * 100).to_i : 100
      default_preserve_uv = user_preserve_uv.nil? ? false : user_preserve_uv

      [
        {
          type: :slider,
          id: 'intensity',
          label: 'Regularize Intensity',
          min: 0,
          max: 100,
          default: default_intensity,  # FIXED: Read from SettingsManager
          divisor: 100
        },
        {
          type: :checkbox,
          id: 'preserve_uv',
          label: 'Preserve UV Coordinates',
          default: default_preserve_uv  # FIXED: Read from SettingsManager
        }
      ]
    end

    # Handle preview update (live preview during slider drag).
    #
    # Called continuously while user drags slider.
    # Updates geometry in real-time for immediate feedback.
    #
    # UV RESTORATION: NO (performance optimization)
    # During drag, texture may appear distorted temporarily.
    # UV will be restored on slider release (on_update).
    #
    # @param params [Hash] Parameter values from dialog
    #   - 'intensity': String "0" to "100"
    #   - 'preserve_uv': Boolean true/false
    # @return [void]
    #
    def on_preview(params)
      intensity = params['intensity'].to_f / 100.0

      # Apply transformation without UV restore (performance)
      @tool.send(:mp3d_cq_apply_transformation, intensity)

      # Update tool state for consistency
      @tool.instance_variable_set(:@last_intensity, intensity)
      @tool.instance_variable_set(:@last_preserve_uv, params['preserve_uv'])
    end

    # Handle update (slider release).
    #
    # Called when user releases slider after dragging.
    # Applies final transformation and restores UV coordinates.
    #
    # UV RESTORATION: YES, conditionally based on checkbox state
    # (FIXED - now passes preserve_uv flag to restore())
    # This ensures texture is correct when user stops dragging.
    #
    # @param params [Hash] Parameter values
    # @return [void]
    #
    def on_update(params)
      intensity = params['intensity'].to_f / 100.0
      preserve_uv = params['preserve_uv']  # Current checkbox state

      # Apply transformation
      @tool.send(:mp3d_cq_apply_transformation, intensity)

      # Update tool state
      @tool.instance_variable_set(:@last_intensity, intensity)
      @tool.instance_variable_set(:@last_preserve_uv, preserve_uv)

      # Restore UV coordinates conditionally (FIXED)
      # CRITICAL: Pass preserve_uv flag to restore()
      # This allows user to toggle checkbox and see immediate effect
      uv_session = @tool.instance_variable_get(:@uv_session)
      uv_session.restore(preserve_uv) if uv_session
    end

    # Handle apply button.
    #
    # Commits operation and returns to selection tool.
    # Adds operation to undo stack (user can undo with Ctrl+Z).
    #
    # UV RESTORATION: YES, conditionally based on checkbox state
    # (FIXED - now passes preserve_uv flag to restore())
    # Ensures final geometry has correct texture mapping.
    #
    # @param params [Hash] Parameter values
    # @return [void]
    #
    def on_apply(params)
      intensity = params['intensity'].to_f / 100.0
      preserve_uv = params['preserve_uv']  # Current checkbox state

      # Apply final transformation
      @tool.send(:mp3d_cq_apply_transformation, intensity)

      # Update tool state
      @tool.instance_variable_set(:@last_intensity, intensity)
      @tool.instance_variable_set(:@last_preserve_uv, preserve_uv)

      # Restore UV coordinates conditionally (FIXED)
      # CRITICAL: Pass preserve_uv flag to restore()
      uv_session = @tool.instance_variable_get(:@uv_session)
      uv_session.restore(preserve_uv) if uv_session

      # Commit and cleanup
      @tool.send(:mp3d_cq_commit_and_cleanup)
    end

    # Handle cancel button.
    #
    # Aborts operation and returns to selection tool.
    # Restores geometry to pre-tool state and restores original selection.
    #
    # @return [void]
    #
    def on_cancel
      @tool.send(:mp3d_cq_abort_and_cleanup)
    end

    # Handle dialog closed event (X button on title bar).
    #
    # Called when user closes dialog via X button.
    # Ensures operation is aborted (same as Cancel button).
    #
    # @return [void]
    #
    def on_dialog_closed
      on_cancel
    end
  end

  #======================================================================
  # TOOL INSTANCE (SketchUp Tool API)
  #======================================================================
  
  # SketchUp Tool instance for Regularize.
  #
  # This makes Regularize a proper SketchUp tool that:
  # - Exits other tools when activated (including selection tool)
  # - Can be exited with ESC or by selecting another tool
  # - Cancels operation when deactivated without Apply
  # - Returns to selection tool on exit
  #
  class RegularizeToolInstance
    # Initialize tool instance.
    #
    # @param runner [Module] RegularizeTool module
    #
    def initialize(runner)
      @runner = runner
    end

    # Tool activated callback.
    #
    # Called when tool becomes active.
    # Starts interactive session.
    #
    # @return [void]
    #
    def activate
      @runner.send(:mp3d_cq_start_session)
    end

    # Tool deactivated callback (user switched to another tool or pressed ESC).
    #
    # Called when tool loses focus.
    # Cancels operation and restores geometry.
    #
    # @param view [Sketchup::View] The view
    # @return [void]
    #
    def deactivate(view)
      # Cancel operation if user exits tool without clicking Apply
      @runner.send(:mp3d_cq_abort_and_cleanup)
    end

    # Handle ESC key (cancel and exit).
    #
    # User presses ESC to cancel operation.
    # Aborts and returns to selection tool.
    #
    # @param flags [Integer] Key flags
    # @param view [Sketchup::View] The view
    # @return [Boolean] true if handled
    #
    def onCancel(flags, view)
      @runner.send(:mp3d_cq_abort_and_cleanup)
      true
    end

    # Resume tool (called when tool regains focus).
    #
    # @param view [Sketchup::View] The view
    # @return [void]
    #
    def resume(view)
      # Nothing needed here
    end

    # Suspend tool (called when tool loses focus temporarily).
    #
    # @param view [Sketchup::View] The view
    # @return [void]
    #
    def suspend(view)
      # Nothing needed here
    end
  end

end # module RegularizeTool
end # module Tools
end # module CurvyQuads
end # module MarcelloPanicciaTools
