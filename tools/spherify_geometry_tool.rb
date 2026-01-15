# frozen_string_literal: true

#==============================================================================
# CurvyQuads - Spherify Geometry Tool
#==============================================================================
# Tool: Spherify Geometry (Raw Edges/Faces Only)
# Purpose: Spherical deformation for raw geometry within edit context
# Source: Logic from spherify_v1_7.rb (split for geometry scope)
#
# Scope Restrictions:
# - REQUIRES editing inside Group/Component (active_path != nil)
# - BLOCKS execution if edit context contains nested Groups/Components
# - BLOCKS execution if selection contains Groups/Components
# - Raw geometry only: edges and faces
#
# Features:
# - Mandatory triangulation before deformation (shared GeometryUtils)
# - Two sliders: Amount (0-100%) and Radius Multiplier (0.5x-1.5x)
# - UV preservation optional (UVSession pattern)
# - Live preview with selection tracking (shared SelectionTracker)
# - Tool conflict prevention (shared ToolManager)
# - Idle mode support (opens without selection, waits for user input)
#
# PDF Reference: Section 7B (Spherify Geometry)
#==============================================================================

module MarcelloPanicciaTools
module CurvyQuads
module Tools
module SpherifyGeometryTool
  extend self

  TOOL_NAME = 'Spherify Geometry'
  PREF_KEY = 'MarcelloPanicciaTools_CurvyQuads_SpherifyGeometry'

  # Tool state
  @model = nil
  @selection = nil
  @entities = nil
  @dialog = nil
  @tracker = nil

  # Geometry data
  @vertices = []
  @original_positions = {}
  @center = nil
  @radius = 0

  # UV session
  @uv_session = nil

  # Operation state
  @operation_started = false

  # Last preserve_uv state (tracked for selection change UV restore)
  @last_preserve_uv = false

  #======================================================================
  # ACTIVATION
  #======================================================================

  # Activate Spherify Geometry tool.
  #
  # Entry point for tool activation.
  # Validates context before starting (selection validation deferred to idle mode).
  #
  # @return [void]
  #
  # @example Toolbar button click
  #   SpherifyGeometryTool.activate
  #
  def activate
    @model = ::Sketchup.active_model
    @selection = @model.selection
    @entities = @model.active_entities

    # Check ToolManager mutex
    unless Shared::ToolManager.activate_tool(TOOL_NAME, self)
      return # Another tool is active, abort
    end

    # Validate edit context (must be inside Group/Component)
    unless validate_edit_context
      Shared::ToolManager.deactivate_tool(TOOL_NAME)
      return
    end

    # Initialize last preserve_uv state
    @last_preserve_uv = false

    # Start operation
    @model.start_operation(TOOL_NAME, false)
    @operation_started = true

    # Setup selection tracking
    setup_selection_tracking

    # Create dialog
    create_dialog

    # Initial geometry processing (may be empty if no selection)
    refresh_geometry_session
  end

  #======================================================================
  # VALIDATION (Scope Restrictions)
  #======================================================================

  # Validate that we're inside a Group/Component edit context.
  #
  # Spherify Geometry is ILLEGAL in "World" context (model root).
  # User must double-click into a Group/Component first.
  #
  # Also checks for nested containers.
  # If edit context contains nested Groups/Components → ERROR + ABORT
  #
  # @return [Boolean] true if valid edit context
  #
  def validate_edit_context
    # Check if active_path is nil (World context)
    if @model.active_path.nil? || @model.active_path.empty?
      ::UI.messagebox(
        "Spherify Geometry requires editing inside a Group or Component without nested Groups/Components.\n\n" \
        "Please:\n" \
        "1. Double-click a Group/Component to enter edit mode\n" \
        "2. Run Spherify Geometry again\n" \
        "3. Select raw geometry (edges/faces)\n\n" \
        "Note: Use 'Spherify Objects' for Group/Component selection",
        MB_OK
      )
      return false
    end

    # Check for nested containers (ILLEGAL)
    has_nested = @entities.any? { |e| e.is_a?(::Sketchup::Group) || e.is_a?(::Sketchup::ComponentInstance) }

    if has_nested
      ::UI.messagebox(
        "Spherify Geometry cannot operate on contexts with nested Groups/Components.\n\n" \
        "Please:\n" \
        "1. Edit a simpler container (no nested objects), OR\n" \
        "2. Use 'Spherify Objects' to deform entire Groups/Components\n\n" \
        "Note: This restriction ensures stability and predictable results.",
        MB_OK
      )
      return false
    end

    true
  end

  # Validate selection contains only raw geometry.
  #
  # BLOCKS execution if selection contains Groups or Components.
  #
  # @return [Boolean] true if valid
  #
  def validate_selection
    # Check for Groups/Components in selection (ILLEGAL)
    has_containers = @selection.any? do |entity|
      entity.is_a?(::Sketchup::Group) || entity.is_a?(::Sketchup::ComponentInstance)
    end

    if has_containers
      ::UI.messagebox(
        "Spherify Geometry works only on raw edges and faces.\n\n" \
        "Your selection contains Groups or Components.\n\n" \
        "Please:\n" \
        "- Select only edges/faces, OR\n" \
        "- Use 'Spherify Objects' for Group/Component selection",
        MB_OK
      )
      return false
    end

    # Check for valid geometry
    edges = @selection.grep(::Sketchup::Edge)
    faces = @selection.grep(::Sketchup::Face)

    # Return false silently if empty (idle mode)
    return false if edges.empty? && faces.empty?

    true
  end

  #======================================================================
  # SELECTION TRACKING (Shared SelectionTracker)
  #======================================================================

  # Setup selection tracking using shared SelectionTracker.
  #
  # Monitors selection changes and context changes (enter/exit group).
  # On change, calls refresh_geometry_session callback.
  #
  # @return [void]
  #
  def setup_selection_tracking
    @tracker = Shared::SelectionTracker.start_tracking(@model) do
      refresh_geometry_session
    end
  end

  #======================================================================
  # GEOMETRY SESSION
  #======================================================================

  # Refresh geometry session (recalculate center, radius, etc).
  #
  # Called on:
  # - Initial activation
  # - Selection change (via SelectionTracker callback)
  #
  # Workflow:
  # 1. Mark processing (prevents recursive calls)
  # 2. Restart operation (abort previous, start new)
  # 3. Extract vertices from selection
  # 4. If empty, enter idle mode (wait for selection)
  # 5. Validate selection (containers check)
  # 6. Triangulate context (MANDATORY - all faces in context)
  # 7. Cache geometry data (center, radius, original positions)
  # 8. Initialize UV session (ALWAYS capture, restore conditionally)
  # 9. Apply initial preview
  # 10. Restore UV if preserve_uv is active (selection change UV restore)
  #
  # @return [void]
  #
  def refresh_geometry_session
    @tracker.processing = true

    # Restart operation (abort previous uncommitted changes)
    @model.abort_operation if @operation_started
    @model.start_operation(TOOL_NAME, false)
    @operation_started = true

    # Extract vertices from selection
    extract_vertices

    # Idle mode: if empty, wait for selection
    if @vertices.empty?
      @tracker.processing = false
      @model.active_view.invalidate
      return
    end

    # Validate selection (containers check)
    unless validate_selection
      @tracker.processing = false
      @model.active_view.invalidate
      return
    end

    begin
      # Step 1: Triangulate context (MANDATORY)
      triangulate_context

      # Step 2: Cache geometry data (center, radius, original positions)
      cache_geometry_data

      # Step 3: Initialize UV session (ALWAYS capture)
      @uv_session = Shared::UVHelper::UVSession.new(@vertices)

      # Step 4: Apply initial preview (amount=100%, radius_mult=100%)
      update_geometry(1.0, 1.0, false)

      # Step 5: Restore UV if preserve_uv checkbox is active
      # This ensures UV is restored when selection changes
      if @last_preserve_uv && @uv_session
        @uv_session.restore(true)
      end

    rescue => e
      puts "[Spherify Geometry] Error: #{e.message}"
      puts e.backtrace.join("\n")
      @model.abort_operation if @operation_started
      @operation_started = false
    end

    @tracker.processing = false
  end

  # Extract vertices from selection.
  #
  # Collects unique vertices from selected faces and edges.
  #
  # @return [void]
  #
  def extract_vertices
    @vertices = []
    @selection.grep(::Sketchup::Face).each { |f| @vertices.concat(f.vertices) }
    @selection.grep(::Sketchup::Edge).each { |e| @vertices.concat(e.vertices) }
    @vertices.uniq!
  end

  #======================================================================
  # TRIANGULATION (Shared GeometryUtils)
  #======================================================================

  # Triangulate active context (MANDATORY).
  #
  # Uses shared GeometryUtils.mp3d_cq_triangulate_faces.
  # Triangulates ALL faces in active context (not just selection).
  #
  # This is CRITICAL for:
  # - Stable vertex order (UV preservation)
  # - Preventing autofold (predictable topology)
  # - QFT compatibility (TopologyAnalyzer)
  #
  # @return [void]
  #
  def triangulate_context
    all_faces = @entities.grep(::Sketchup::Face)
    stats = Shared::GeometryUtils.mp3d_cq_triangulate_faces(@entities, all_faces)
    puts "[Spherify Geometry] Triangulation: #{stats[:edges_added]} edges added"
  end

  #======================================================================
  # GEOMETRY PROCESSING
  #======================================================================

  # Cache geometry data (center, radius, original positions).
  #
  # Calculates bounding box center and radius.
  # Stores original vertex positions for interpolation.
  #
  # @return [void]
  #
  def cache_geometry_data
    @original_positions = {}

    # Calculate bounding box
    bb = ::Geom::BoundingBox.new
    @vertices.each do |v|
      pos = v.position
      @original_positions[v] = pos.clone
      bb.add(pos)
    end

    @center = bb.center
    @radius = [bb.width, bb.height, bb.depth].max / 2.0
  end

  # Update geometry with spherify transformation.
  #
  # For each vertex:
  # 1. Calculate direction from center to original position
  # 2. Project onto sphere surface (radius * radius_mult)
  # 3. Blend between original and target based on amount
  # 4. Apply transformation using transform_by_vectors
  #
  # UV Restoration:
  # - Called conditionally based on preserve_uv parameter
  # - Matches Regularize pattern (restore in on_update and on_apply)
  #
  # @param amount [Float] Amount 0.0 to 1.0 (0% to 100%)
  # @param radius_mult [Float] Radius multiplier 0.5 to 1.5
  # @param restore_uv_now [Boolean] Whether to restore UV immediately
  # @return [void]
  #
  def update_geometry(amount, radius_mult, restore_uv_now = false)
    return if @vertices.empty?

    verts_ordered = []
    vectors = []
    actual_radius = @radius * radius_mult

    @vertices.each do |v|
      next unless v.valid?

      original_pos = @original_positions[v]
      next unless original_pos

      vec_from_center = original_pos - @center

      if vec_from_center.length < 1.0e-6
        target_pos = @center
      else
        direction = vec_from_center.normalize
        target_pos = @center.offset(direction, actual_radius)
      end

      final_pos = ::Geom::Point3d.new(
        original_pos.x + (target_pos.x - original_pos.x) * amount,
        original_pos.y + (target_pos.y - original_pos.y) * amount,
        original_pos.z + (target_pos.z - original_pos.z) * amount
      )

      move_vec = final_pos - v.position

      if move_vec.length > 1.0e-5
        verts_ordered << v
        vectors << move_vec
      end
    end

    unless verts_ordered.empty?
      @entities.transform_by_vectors(verts_ordered, vectors)
    end

    if restore_uv_now && @uv_session
      @uv_session.restore(true)
    end

    @model.active_view.invalidate
  end

  #======================================================================
  # DIALOG
  #======================================================================

  # Create parameter dialog using DialogBase.
  #
  # Dialog provides:
  # - Amount slider (0-100%)
  # - Radius multiplier slider (50-150%, represents 0.5x-1.5x)
  # - Preserve UV checkbox
  #
  # @return [void]
  #
  def create_dialog
    @dialog = SpherifyGeometryDialog.new(self)
    @dialog.create_dialog
  end

  # Handle parameter update from dialog (live preview).
  #
  # Called during slider drag.
  #
  # @param params [Hash] Dialog parameters
  #   - 'amount': String "0" to "100"
  #   - 'radius_mult': String "50" to "150"
  #   - 'preserve_uv': Boolean
  # @return [void]
  #
  def on_preview(params)
    amount = params['amount'].to_f / 100.0
    radius_mult = params['radius_mult'].to_f / 100.0

    # Update last preserve_uv state
    @last_preserve_uv = params['preserve_uv']

    update_geometry(amount, radius_mult, false)
  end

  # Handle parameter update from dialog (slider release).
  #
  # @param params [Hash] Dialog parameters
  # @return [void]
  #
  def on_update(params)
    amount = params['amount'].to_f / 100.0
    radius_mult = params['radius_mult'].to_f / 100.0
    preserve_uv = params['preserve_uv']

    # Update last preserve_uv state
    @last_preserve_uv = preserve_uv

    update_geometry(amount, radius_mult, preserve_uv)
  end

  # Handle apply button.
  #
  # Commits operation and returns to selection tool.
  #
  # @param params [Hash] Dialog parameters
  # @return [void]
  #
  def on_apply(params)
    amount = params['amount'].to_f / 100.0
    radius_mult = params['radius_mult'].to_f / 100.0
    preserve_uv = params['preserve_uv']

    # Update last preserve_uv state
    @last_preserve_uv = preserve_uv

    update_geometry(amount, radius_mult, preserve_uv)

    cleanup
    @model.commit_operation if @operation_started
    @operation_started = false
  end

  # Handle cancel button.
  #
  # Aborts operation and returns to selection tool.
  #
  # @return [void]
  #
  def on_cancel
    # Restore UV coordinates before aborting (fixes texture corruption)
    @uv_session.restore(true) if @uv_session

    cleanup
    @model.abort_operation if @operation_started
    @operation_started = false
  end

  #======================================================================
  # CLEANUP
  #======================================================================

  # Cleanup observers, timers, and dialogs.
  #
  # Called on:
  # - Apply (commit)
  # - Cancel (abort)
  # - Context change (via SelectionTracker)
  #
  # @return [void]
  #
  def cleanup
    @tracker.stop if @tracker
    @tracker = nil

    if @dialog
      @dialog.close_dialog rescue nil
      @dialog = nil
    end

    Shared::ToolManager.deactivate_tool(TOOL_NAME)

    @uv_session = nil
    @vertices = []
    @original_positions = {}
    @last_preserve_uv = false
  end

end # module SpherifyGeometryTool

#========================================================================
# DIALOG
#========================================================================

# Dialog class for Spherify Geometry (extends DialogBase).
#
# Provides:
# - Amount slider (0-100%)
# - Radius multiplier slider (50-150%, represents 0.5x-1.5x)
# - Preserve UV checkbox
# - Reset button (loads user defaults from SettingsManager)
#
class SpherifyGeometryDialog < Shared::DialogBase

  # Initialize dialog.
  #
  # @param tool [Module] SpherifyGeometryTool module
  #
  def initialize(tool)
    super(SpherifyGeometryTool::TOOL_NAME, SpherifyGeometryTool::PREF_KEY)
    @tool = tool
  end

  # Define control configuration.
  #
  # @return [Array<Hash>] Control definitions
  #
  def control_config
    [
      {
        type: :slider,
        id: 'amount',
        label: 'Spherify Amount',
        min: 0,
        max: 100,
        default: 100,
        divisor: 100
      },
      {
        type: :slider,
        id: 'radius_mult',
        label: 'Radius Multiplier',
        min: 50,
        max: 150,
        default: 100,
        divisor: 100
      },
      {
        type: :checkbox,
        id: 'preserve_uv',
        label: 'Preserve UV Coordinates',
        default: false
      }
    ]
  end

  # Get user defaults from SettingsManager.
  #
  # Overrides base class to read actual user defaults instead of factory defaults.
  # Called when user presses Reset button in dialog.
  #
  # Base class get_user_defaults() returns ctrl[:default] from control_config (factory defaults).
  # We override to read from SettingsManager.mp3d_cq_get_parameter() (user's custom defaults).
  #
  # @return [Hash] User default values
  #
  def get_user_defaults
    amount = Shared::SettingsManager.mp3d_cq_get_parameter('spherify_geometry', 'amount')
    radius_mult = Shared::SettingsManager.mp3d_cq_get_parameter('spherify_geometry', 'radius_mult')
    preserve_uv = Shared::SettingsManager.mp3d_cq_get_parameter('spherify_geometry', 'preserve_uv')

    {
      'amount' => amount ? (amount * 100).to_i : 100,
      'radius_mult' => radius_mult ? (radius_mult * 100).to_i : 100,
      'preserve_uv' => preserve_uv || false
    }
  end

  # Handle preview update (slider drag).
  #
  # @param params [Hash] Parameter values
  # @return [void]
  #
  def on_preview(params)
    @tool.on_preview(params)
  end

  # Handle update (slider release).
  #
  # @param params [Hash] Parameter values
  # @return [void]
  #
  def on_update(params)
    @tool.on_update(params)
  end

  # Handle apply button.
  #
  # @param params [Hash] Parameter values
  # @return [void]
  #
  def on_apply(params)
    @tool.on_apply(params)
  end

  # Handle cancel button.
  #
  # @return [void]
  #
  def on_cancel
    @tool.on_cancel
  end

  # Handle dialog closed event (X button).
  #
  # Ensures proper cleanup when user closes dialog with X button
  # instead of Cancel button.
  #
  # @return [void]
  #
  def on_dialog_closed
    @tool.on_cancel
  end

end

end # module Tools
end # module CurvyQuads
end # module MarcelloPanicciaTools
