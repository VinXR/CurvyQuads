# frozen_string_literal: true

#==============================================================================
# CurvyQuads - Spherify Objects Tool
#==============================================================================
# Tool: Spherify Objects (Groups/Components Only)
# Purpose: Spherical deformation for Groups and ComponentInstances
# Source: Logic from spherify_v1_7.rb (container handling)
#
# Scope Restrictions:
# - ONLY works on Groups and ComponentInstances
# - Components: Modifies definition (updates ALL instances)
# - Groups: Applies make_unique (always, like v1.7)
# - Nested containers: SKIP silently
# - Raw geometry mixed: SKIP silently (log only)
#
# Key Features:
# - Mandatory triangulation before deformation (shared GeometryUtils)
# - Two sliders: Amount (0-100%) and Radius Multiplier (0.5x-1.5x)
# - UV preservation optional (UVSession pattern)
# - Live preview with selection tracking (shared SelectionTracker)
# - Tool conflict prevention (shared ToolManager)
# - Idle mode support (opens without selection, waits for user input)
#
# Key Differences from Spherify Geometry:
# - NO edit context requirement (can work in World)
# - Triangulation INSIDE each container (not context-wide)
# - make_unique handling for Groups (always, like v1.7)
# - Component definition trick (temp cpoint for bbox refresh)
#
# PDF Reference: Section 7C (Spherify Objects)
# Transition Doc: Section 6.2 (DECISIONE #2, #4, #5)
#==============================================================================

module MarcelloPanicciaTools
module CurvyQuads
module Tools
module SpherifyObjectsTool
  extend self

  TOOL_NAME = 'Spherify Objects'
  PREF_KEY = 'MarcelloPanicciaTools_CurvyQuads_SpherifyObjects'

  # Tool state
  @model = nil
  @selection = nil
  @dialog = nil
  @tracker = nil

  # Target data (array of hashes)
  @targets = []

  # Operation state
  @operation_started = false

  # Last preserve_uv state (tracked for selection change UV restore)
  @last_preserve_uv = false

  #======================================================================
  # ACTIVATION
  #======================================================================

  # Activate Spherify Objects tool.
  #
  # Entry point for tool activation.
  # No selection validation required - idle mode supported.
  #
  # @return [void]
  #
  # @example Toolbar button click
  #   SpherifyObjectsTool.activate
  #
  def activate
    @model = ::Sketchup.active_model
    @selection = @model.selection

    # Check ToolManager mutex
    unless Shared::ToolManager.activate_tool(TOOL_NAME, self)
      return # Another tool is active, will be closed automatically
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

    # Initial geometry processing (may be empty if no selection - idle mode)
    refresh_geometry_session
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

  # Refresh geometry session (recalculate targets, center, radius, etc).
  #
  # Called on:
  # - Initial activation
  # - Selection change (via SelectionTracker callback)
  #
  # Workflow:
  # 1. Mark processing (prevents recursive calls)
  # 2. Restart operation (abort previous, start new)
  # 3. Setup targets from selection (filter containers)
  # 4. If empty, enter idle mode (wait for selection)
  # 5. For each target:
  #    - Prepare target (make_unique for groups, get definition for components)
  #    - Triangulate target entities (MANDATORY)
  #    - Cache geometry data (center, radius, original positions)
  #    - Initialize UV session (ALWAYS capture, restore conditionally)
  # 6. Apply initial preview
  # 7. Restore UV if preserve_uv is active (selection change UV restore)
  #
  # @return [void]
  #
  def refresh_geometry_session
    @tracker.processing = true

    # Restart operation (abort previous uncommitted changes)
    @model.abort_operation if @operation_started
    @model.start_operation(TOOL_NAME, false)
    @operation_started = true

    # Setup targets from selection
    setup_targets(@selection.to_a)

    # Idle mode: if empty, wait for selection
    if @targets.empty?
      @tracker.processing = false
      @model.active_view.invalidate
      return
    end

    begin
      # Process each target
      @targets.each do |target|
        # Step 1: Prepare target (make_unique, get entities)
        prepare_target(target)

        # Step 2: Triangulate target entities (MANDATORY)
        triangulate_target(target)

        # Step 3: Cache geometry data (center, radius, original positions)
        cache_target_data(target)

        # Step 4: Initialize UV session (ALWAYS capture)
        target[:uv_session] = Shared::UVHelper::UVSession.new(target[:vertices])
      end

      # Step 5: Apply initial preview (amount=100%, radius_mult=100%)
      update_geometry(1.0, 1.0, false)

      # Step 6: Restore UV if preserve_uv checkbox is active
      # This ensures UV is restored when selection changes
      if @last_preserve_uv
        @targets.each do |target|
          target[:uv_session].restore(true) if target[:uv_session]
        end
      end

    rescue => e
      puts "[Spherify Objects] Error: #{e.message}"
      puts e.backtrace.join("\n")
      @model.abort_operation if @operation_started
      @operation_started = false
    end

    @tracker.processing = false
  end

  #======================================================================
  # TARGET SETUP
  #======================================================================

  # Setup targets from selection.
  #
  # Filters Groups and ComponentInstances from selection.
  # Skips nested containers silently (too complex).
  # Skips raw geometry silently (log only).
  #
  # Each target is a hash containing:
  # - :entity - Original Group/ComponentInstance reference
  # - :definition - Definition reference (for both Groups and Components)
  # - :is_group - Boolean flag (true for Group, false for ComponentInstance)
  # - :entities - Entities collection to work on
  # - :vertices - Array of vertices
  # - :original_positions - Hash {vertex => position}
  # - :center - Center point
  # - :radius - Radius
  # - :uv_session - UVSession object
  #
  # @param selection_array [Array] Selected entities
  # @return [void]
  #
  def setup_targets(selection_array)
    @targets = []

    # Filter containers (ROBUST: use is_a? not respond_to?)
    groups = selection_array.grep(::Sketchup::Group)
    components = selection_array.select { |e| e.is_a?(::Sketchup::ComponentInstance) }

    # Check for raw geometry mixed (SKIP SILENTLY - DECISIONE #5)
    has_raw_geometry = selection_array.any? do |entity|
      entity.is_a?(::Sketchup::Edge) || entity.is_a?(::Sketchup::Face)
    end

    if has_raw_geometry
      puts "[Spherify Objects] Raw geometry in selection - ignored (#{groups.size + components.size} containers processed)"
    end

    # No containers? Stay in idle mode (no error message)
    return if groups.empty? && components.empty?

    # Process containers
    containers = groups + components

    containers.each do |container|
      # Get definition
      if container.is_a?(::Sketchup::Group)
        definition = container.entities.parent
      else
        # ComponentInstance
        definition = container.definition
      end

      # Check for nested containers (SKIP SILENTLY - DECISIONE #1)
      has_nested = definition.entities.any? do |e|
        e.is_a?(::Sketchup::Group) || e.is_a?(::Sketchup::ComponentInstance)
      end

      if has_nested
        puts "[Spherify Objects] Skipping nested container: #{container}"
        next
      end

      # Create target hash
      target = {
        entity: container,
        definition: definition,
        is_group: container.is_a?(::Sketchup::Group),
        entities: nil,
        vertices: [],
        original_positions: {},
        center: nil,
        radius: 0,
        uv_session: nil
      }

      @targets << target
    end
  end

  # Prepare target for deformation.
  #
  # Groups: Apply make_unique ALWAYS (like v1.7 - DECISIONE #4)
  # Components: Work directly on definition (updates ALL instances - intentional)
  #
  # @param target [Hash] Target data
  # @return [void]
  #
  def prepare_target(target)
    if target[:is_group]
      # Groups: make_unique ALWAYS (like v1.7 standalone)
      group = target[:entity]
      group.make_unique
      target[:definition] = group.entities.parent
      target[:entities] = group.entities
    else
      # Components: Work on definition (affects ALL instances - intentional)
      component = target[:entity]
      target[:entities] = component.definition.entities
    end
  end

  #======================================================================
  # TRIANGULATION (Shared GeometryUtils)
  #======================================================================

  # Triangulate target entities (MANDATORY - DECISIONE #2).
  #
  # Uses shared GeometryUtils.mp3d_cq_triangulate_faces.
  # Triangulates ALL faces in target (not just selection).
  #
  # This is CRITICAL for:
  # - Stable vertex order (UV preservation)
  # - Preventing autofold (predictable topology)
  # - Algorithm coherence (same as Spherify Geometry)
  #
  # @param target [Hash] Target data
  # @return [void]
  #
  def triangulate_target(target)
    all_faces = target[:entities].grep(::Sketchup::Face)
    stats = Shared::GeometryUtils.mp3d_cq_triangulate_faces(target[:entities], all_faces)
    puts "[Spherify Objects] Target triangulated: #{stats[:edges_added]} edges added"
  end

  #======================================================================
  # GEOMETRY PROCESSING
  #======================================================================

  # Cache target geometry data.
  #
  # Calculates bounding box center and radius.
  # Stores original vertex positions for interpolation.
  #
  # @param target [Hash] Target data
  # @return [void]
  #
  def cache_target_data(target)
    # Get all vertices from target entities
    target[:vertices] = target[:entities].grep(::Sketchup::Edge).flat_map(&:vertices).uniq

    # Calculate bounding box center and radius
    bb = ::Geom::BoundingBox.new
    target[:vertices].each do |v|
      pos = v.position
      target[:original_positions][v] = pos.clone
      bb.add(pos)
    end

    target[:center] = bb.center
    target[:radius] = [bb.width, bb.height, bb.depth].max / 2.0
  end

  # Update geometry with spherify transformation.
  #
  # For each target, for each vertex:
  # 1. Calculate direction from center to original position
  # 2. Project onto sphere surface (radius * radius_mult)
  # 3. Blend between original and target based on amount
  # 4. Apply transformation using transform_by_vectors
  #
  # Component Definition Trick:
  # - For components, add/remove temp cpoint to force bbox refresh
  # - This ensures SketchUp updates all instances correctly
  #
  # UV Restoration:
  # - Called conditionally based on preserve_uv parameter
  # - Matches Regularize/Spherify Geometry pattern (restore in on_update and on_apply)
  #
  # @param amount [Float] Amount 0.0 to 1.0 (0% to 100%)
  # @param radius_mult [Float] Radius multiplier 0.5 to 1.5
  # @param restore_uv_now [Boolean] Whether to restore UV immediately
  # @return [void]
  #
  def update_geometry(amount, radius_mult, restore_uv_now = false)
    return if @targets.empty?

    @targets.each do |target|
      verts_ordered = []
      vectors = []
      actual_radius = target[:radius] * radius_mult

      target[:vertices].each do |v|
        next unless v.valid?

        original_pos = target[:original_positions][v]
        next unless original_pos

        vec_from_center = original_pos - target[:center]

        if vec_from_center.length < 1.0e-6
          target_pos = target[:center]
        else
          direction = vec_from_center.normalize
          target_pos = target[:center].offset(direction, actual_radius)
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

      # Apply transformation
      unless verts_ordered.empty?
        target[:entities].transform_by_vectors(verts_ordered, vectors)

        # Component definition trick: force bbox refresh (v1.7 legacy)
        unless target[:is_group]
          temp = target[:entities].add_cpoint(::Geom::Point3d.new(0, 0, 0))
          temp.erase!
        end
      end

      # Restore UV if needed
      if restore_uv_now && target[:uv_session]
        target[:uv_session].restore(true)
      end
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
    @dialog = SpherifyObjectsDialog.new(self)
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
  # Commits operation and closes tool.
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
  # Aborts operation and closes tool.
  #
  # @return [void]
  #
  def on_cancel
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

    @targets = []
    @last_preserve_uv = false
  end

end # module SpherifyObjectsTool

#========================================================================
# DIALOG
#========================================================================

# Dialog class for Spherify Objects (extends DialogBase).
#
# Provides:
# - Amount slider (0-100%)
# - Radius multiplier slider (50-150%, represents 0.5x-1.5x)
# - Preserve UV checkbox
# - Reset button (loads user defaults from SettingsManager)
#
class SpherifyObjectsDialog < Shared::DialogBase

  # Initialize dialog.
  #
  # @param tool [Module] SpherifyObjectsTool module
  #
  def initialize(tool)
    super(SpherifyObjectsTool::TOOL_NAME, SpherifyObjectsTool::PREF_KEY)
    @tool = tool
  end

  # Define control configuration.
  #
  # @return [Array] Control definitions
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
    amount = Shared::SettingsManager.mp3d_cq_get_parameter('spherify_objects', 'amount')
    radius_mult = Shared::SettingsManager.mp3d_cq_get_parameter('spherify_objects', 'radius_mult')
    preserve_uv = Shared::SettingsManager.mp3d_cq_get_parameter('spherify_objects', 'preserve_uv')

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
  # Preserves entire undo stack (abort operation, no commit).
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
