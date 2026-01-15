# frozen_string_literal: true

#==============================================================================
# CurvyQuads - UV Coordinate Preservation Module
#==============================================================================
# Module: UVHelper
# Purpose: Capture and restore UV texture coordinates during geometry
# transformations to prevent texture distortion.

# This module provides both LOW-LEVEL helper methods (capture/restore) and
# a HIGH-LEVEL session manager (UVSession class) for automatic UV handling.

# Architecture:
# - UVHelper module: Stateless helper methods (capture_uv_data, restore_uv_data)
# - UVSession class: Stateful session manager (one instance per tool operation)

# Why Session Manager Pattern:
# All 4 tools (Regularize, Spherify Geometry, Spherify Objects, Set Flow)
# need identical UV preservation logic:
# 1. Capture UV before first deformation
# 2. Restore UV on slider release (not during drag - performance)
# 3. Restore UV on Apply/OK

# By centralizing this logic in UVSession, we avoid code duplication and
# ensure consistent behavior across all tools.

# Usage Pattern (for tool developers):
# ---------------------------------
# Step 1: Create session at tool start
# @uv_session = Shared::UVHelper::UVSession.new(vertices)
#
# Step 2: In on_preview callback (slider drag):
# transform_geometry()
# # DO NOT restore UV (performance + live preview)
#
# Step 3: In on_update callback (slider release):
# transform_geometry()
# @uv_session.restore(preserve_uv_checkbox_state) # Restore UV conditionally
#
# Step 4: In on_apply callback (Apply/OK button):
# transform_geometry()
# @uv_session.restore(preserve_uv_checkbox_state) # Restore UV conditionally

# Algorithm Details (Spherify v1.7 Proven Method):
# ------------------------------------------------
# UV coordinates are captured ONCE before any deformation.
# SketchUp's get_front_UVQ/get_back_UVQ methods READ the UV coordinates
# that SketchUp has already stored for each vertex in each face.
# These UV coordinates are INDEPENDENT of 3D position.

# When we restore, we tell SketchUp:
# "The vertex that is NOW at position (x2, y2, z2) [deformed]
# should have the SAME UV coordinates it had when it was at (x1, y1, z1) [original]"

# This works because:
# 1. Vertex objects are Ruby references (stay same after transform_by_vectors)
# 2. vertex.position method returns CURRENT position (auto-updated by SketchUp)
# 3. UV coordinates are frozen at capture time (stored in our data structure)
# 4. position_material re-maps texture using: [current_pos, original_uv] pairs

# Why Pre-Triangulation is Critical:
# ---------------------------------
# SketchUp implicitly triangulates non-triangular faces for rendering.
# Without explicit QFT-compliant triangulation BEFORE capture:
# - Vertex order may change unpredictably
# - SketchUp may create new vertices/edges (autofold)
# - UV capture would miss these new vertices
# - UV restoration would fail (vertex count mismatch)

# By triangulating first (Step 3 in all tools), we ensure:
# - Stable vertex order
# - No new geometry created during transform
# - UV capture/restore operates on fixed topology

# PDF Reference: Section 6B (Preservazione UV)
# Code Reference: spherify_v1_7.rb (validated implementation)
#==============================================================================

module MarcelloPanicciaTools
module CurvyQuads
module Shared
module UVHelper

extend self

#======================================================================
# LOW-LEVEL API (Stateless Helper Methods)
#======================================================================
# These methods are used internally by UVSession class.
# Tool developers should use UVSession instead of calling these directly.

#======================================================================
# Capture UV coordinates for all textured faces connected to given vertices.

# This method scans all faces connected to the provided vertices and
# captures their UV texture coordinates using SketchUp's TextureWriter API.

# Data Structure (Array of Pairs - NOT Hash):
# We store UV data as Array of [vertex_object, uv_point] pairs because:
# 1. Vertex objects are Ruby references (persist after transform_by_vectors)
# 2. After deformation, vertex.position returns NEW position automatically
# 3. We pair: NEW positions (auto-updated) with OLD UVs (frozen at capture)
# 4. Array guarantees iteration order (critical for position_material API)

# Why NOT Hash:
# Hash {vertex => uv} would work for storage, but:
# - Ruby < 1.9 doesn't guarantee Hash iteration order
# - Array is more explicit about ordering
# - Matches spherify_v1_7.rb proven implementation

# CRITICAL: Must be called AFTER triangulation.
# If called before, SketchUp may implicitly triangulate faces differently,
# breaking the vertex-to-UV mapping.

# Algorithm:
# 1. Create TextureWriter (SketchUp UV extraction API)
# 2. Get all unique faces connected to input vertices
# 3. For each textured face (front and/or back material):
#    a. Load face into TextureWriter (API requirement)
#    b. Get UVHelper (SketchUp API for UV coordinate queries)
#    c. For each vertex in face:
#       - Extract UVQ coordinates (homogeneous form: U, V, Q)
#       - Convert to Cartesian (divide U and V by Q component)
#       - Store as [vertex_object, uv_point] pair in Array
# 4. Return Hash: {face => {mat_front, front_pts, mat_back, back_pts}}

# UVQ Homogeneous Coordinates:
# SketchUp returns UV in homogeneous form (U, V, Q) for perspective-correct
# texture mapping. We convert to Cartesian by dividing: (U/Q, V/Q).
# Handle near-zero Q (edge case): default to Q=1.0 to avoid division by zero.

# @param vertices [Array<Sketchup::Vertex>] Vertices whose connected
#   faces should have UV data captured
#
# @return [Hash] UV data mapping structure:
#   {
#     face_object => {
#       :mat_front => Sketchup::Material (or nil if no front texture),
#       :front_pts => [[vertex1, uv1], [vertex2, uv2], ...] (Array of pairs),
#       :mat_back => Sketchup::Material (or nil if no back texture),
#       :back_pts => [[vertex1, uv1], [vertex2, uv2], ...] (Array of pairs)
#     },
#     ...
#   }
#   Returns empty hash {} if no textured faces found.
#
# @example Internal usage by UVSession
#   vertices = edge_loop.flat_map(&:vertices).uniq
#   uv_data = UVHelper.capture_uv_data(vertices)
#   # Later, after deformation:
#   UVHelper.restore_uv_data(uv_data)
#
# @note This is a LOW-LEVEL method. Tool developers should use UVSession class
#   instead of calling this directly.
#
def capture_uv_data(vertices)
  return {} if vertices.nil? || vertices.empty?
  
  uv_data = {}
  tw = Sketchup.create_texture_writer
  
  # Get all unique faces connected to these vertices
  # (Each vertex may connect to multiple faces in the mesh)
  faces = vertices.flat_map { |v| v.faces }.uniq
  
  faces.each do |face|
    next unless face.valid?
    
    # Check for textured materials on both sides
    mat = face.material
    back_mat = face.back_material
    has_front = mat && mat.texture
    has_back = back_mat && back_mat.texture
    
    # Skip faces with no textures (nothing to preserve)
    next unless has_front || has_back
    
    # Load face into texture writer (SketchUp API requirement for get_UVHelper)
    tw.load(face, true)
    uv_helper = face.get_UVHelper(true, true, tw)
    
    face_store = {}
    
    # ====================================================
    # Capture FRONT face UVs
    # ====================================================
    if has_front
      face_store[:mat_front] = mat
      pts = []  # Array of [vertex, uv_point] pairs
      
      face.vertices.each do |v|
        # Get UV coordinates in homogeneous form (UVQ)
        # Q component is for perspective-correct texture mapping
        uvq = uv_helper.get_front_UVQ(v.position)
        
        # Convert from homogeneous to Cartesian coordinates
        # Formula: (U/Q, V/Q)
        # Handle near-zero Q to avoid division by zero
        q = uvq.z.abs < 1e-6 ? 1.0 : uvq.z
        uv_point = Geom::Point3d.new(uvq.x / q, uvq.y / q, 0)
        
        # Store as [vertex_object, uv_coordinate] pair
        # Vertex object is a Ruby reference (persists after deformation)
        # UV coordinate is frozen at this moment (before deformation)
        pts << [v, uv_point]
      end
      
      face_store[:front_pts] = pts
    end
    
    # ====================================================
    # Capture BACK face UVs (same logic as front)
    # ====================================================
    if has_back
      face_store[:mat_back] = back_mat
      pts = []  # Array of [vertex, uv_point] pairs
      
      face.vertices.each do |v|
        uvq = uv_helper.get_back_UVQ(v.position)
        q = uvq.z.abs < 1e-6 ? 1.0 : uvq.z
        uv_point = Geom::Point3d.new(uvq.x / q, uvq.y / q, 0)
        pts << [v, uv_point]
      end
      
      face_store[:back_pts] = pts
    end
    
    uv_data[face] = face_store
  end
  
  uv_data
end

# Restore UV coordinates to faces after geometry transformation.

# Reapplies UV coordinates captured by capture_uv_data(). This method
# should be called AFTER all vertex transformations are complete.

# Algorithm:
# 1. Iterate captured UV data (Hash of faces)
# 2. For each face (if still valid):
#    a. Build mapping array: [pos1, uv1, pos2, uv2, pos3, uv3, ...]
#       - pos = vertex.position (CURRENT deformed position)
#       - uv = original UV coordinate (frozen at capture time)
#    b. Call face.position_material(material, mapping, front_or_back)
# 3. Silent fail on errors (UV restoration is non-critical)

# Why This Works After Deformation:
# - Vertex objects are Ruby references (stay same after transform_by_vectors)
# - vertex.position method returns CURRENT position (auto-updated by SketchUp)
# - We pair: NEW positions with OLD UVs
# - SketchUp re-maps texture to new geometry using old UV layout
# - Result: Texture "sticks" to vertices despite deformation

# position_material API Format:
# SketchUp expects a flat array: [pos1, uv1, pos2, uv2, ...]
# Where:
# - pos = Geom::Point3d (3D position of vertex)
# - uv = Geom::Point3d (2D UV coordinate, Z component ignored)

# @param uv_data [Hash] UV data returned from capture_uv_data()
#   Format: {face => {:mat_front, :front_pts, :mat_back, :back_pts}}
#   See capture_uv_data documentation for structure details.
#
# @return [void]
#
# @note This method fails silently if faces are no longer valid or
#   if UV restoration encounters errors. UV restoration is considered
#   non-critical (better to complete operation without UVs than to
#   crash entirely and lose all geometric work).
#
# @note Only logs errors in debug mode (Sketchup.debug_mode? = true)
#   to avoid console spam during normal operation.
#
# @example Internal usage by UVSession
#   uv_data = UVHelper.capture_uv_data(vertices)
#   model.active_entities.transform_by_vectors(verts, vectors)
#   UVHelper.restore_uv_data(uv_data)  # Textures preserved!
#
def restore_uv_data(uv_data)
  return if uv_data.nil? || uv_data.empty?
  
  uv_data.each do |face, data|
    # Skip if face was deleted during transformation
    # (Can happen with aggressive geometry operations or SketchUp cleanup)
    next unless face.valid?
    
    # ====================================================
    # Restore FRONT face UVs
    # ====================================================
    if data[:front_pts]
      # Build mapping array: [pos1, uv1, pos2, uv2, ...]
      # Uses CURRENT vertex positions (after deformation)
      # with ORIGINAL UV coordinates (frozen at capture)
      mapping = []
      data[:front_pts].each do |pair|
        vertex = pair[0]      # Vertex object (Ruby reference)
        uv_point = pair[1]    # UV coordinate (frozen at capture time)
        
        # vertex.position returns CURRENT position (deformed)
        # This is the magic: SketchUp auto-updates vertex.position after transform
        mapping << vertex.position  # Current 3D position
        mapping << uv_point         # Original UV coordinate
      end
      
      begin
        # Apply material and UV mapping to front face
        face.material = data[:mat_front]
        face.position_material(face.material, mapping, true)  # true = front
      rescue => e
        # Silent fail - UV restoration is non-critical
        # (Texture may be slightly distorted, but geometry is intact)
        # Only log in debug mode to avoid console spam
        if Sketchup.debug_mode?
          puts "[UVHelper] Front UV restore warning: #{e.message}"
          puts "  Face: #{face.entityID}, Vertices: #{face.vertices.size}"
        end
      end
    end
    
    # ====================================================
    # Restore BACK face UVs (same logic as front)
    # ====================================================
    if data[:back_pts]
      mapping = []
      data[:back_pts].each do |pair|
        vertex = pair[0]      # Vertex object
        uv_point = pair[1]    # UV coordinate
        mapping << vertex.position  # Current position
        mapping << uv_point         # Original UV
      end
      
      begin
        # Apply material and UV mapping to back face
        face.back_material = data[:mat_back]
        face.position_material(face.back_material, mapping, false)  # false = back
      rescue => e
        if Sketchup.debug_mode?
          puts "[UVHelper] Back UV restore warning: #{e.message}"
          puts "  Face: #{face.entityID}, Vertices: #{face.vertices.size}"
        end
      end
    end
  end
end

# Check if any faces in collection have textured materials.

# Helper method to determine if UV preservation is necessary.
# Can be used to conditionally show/enable UV checkbox in tool dialogs.

# Algorithm:
# 1. Iterate all faces
# 2. Check if face.material has texture (front side)
# 3. Check if face.back_material has texture (back side)
# 4. Return true if ANY face has texture on either side

# @param faces [Array<Sketchup::Face>] Faces to check for textures
#
# @return [Boolean] true if any face has front or back texture,
#   false if all faces are untextured or array is empty
#
# @example Conditional UV checkbox in tool dialog
#   selected_faces = selection.grep(Sketchup::Face)
#   if UVHelper.has_textured_faces?(selected_faces)
#     dialog.show_uv_checkbox  # Show UV preservation option
#   else
#     dialog.hide_uv_checkbox  # No textures, hide checkbox
#   end
#
# @note This is a convenience method for UI logic.
#   Tools can always call capture_uv_data (returns {} if no textures).
#   The performance impact of calling capture on untextured geometry is minimal.
#
def has_textured_faces?(faces)
  return false if faces.nil? || faces.empty?
  
  faces.any? do |face|
    next false unless face.valid?
    
    # Check front material
    has_front_texture = face.material && face.material.texture
    
    # Check back material
    has_back_texture = face.back_material && face.back_material.texture
    
    # Return true if either side has texture
    has_front_texture || has_back_texture
  end
end

#======================================================================
# HIGH-LEVEL API (Stateful Session Manager)
#======================================================================
# UVSession class manages UV preservation for a single tool operation.
# Tool developers should use this instead of calling capture/restore directly.
#======================================================================

# UV Session Manager for tool operations.

# This class manages the complete lifecycle of UV preservation during
# a single tool operation (from tool activation to Apply/Cancel).

# CRITICAL DESIGN DECISION (FIX - Session UV Restore):
# ======================================================
# UV data is ALWAYS captured at session creation, regardless of the
# preserve_uv checkbox state. This matches the proven logic from
# spherify_v1_7.rb (lines 180-250).
#
# WHY:
# The user can toggle the "Preserve UV" checkbox at ANY time during
# tool operation (after session is already created). If we only capture
# UV when checkbox is initially checked, and user checks it later,
# there's no UV data to restore!
#
# SOLUTION (matching spherify_v1_7.rb):
# - ALWAYS capture UV at initialization (minimal performance cost)
# - CONDITIONALLY restore based on checkbox state passed to restore()
# - This allows user to toggle checkbox and get immediate effect
#
# Reference: spherify_v1_7.rb lines 180-188 (capture_uvs always runs)
#            spherify_v1_7.rb lines 280-290 (restore conditional on flag)

# Lifecycle:
# 1. Tool creates session: UVSession.new(vertices)
# 2. Session captures UV automatically (ALWAYS, not conditional)
# 3. Tool deforms geometry multiple times (slider drag, etc.)
# 4. Tool calls session.restore(preserve_uv_flag) when needed
# 5. Session is discarded when tool exits

# Benefits vs Manual capture/restore:
# - Automatic capture on initialization
# - Single restore() method (tool doesn't need to manage uv_data)
# - State encapsulation (uv_data storage)
# - Consistent pattern across all 4 tools
# - Supports dynamic checkbox toggling (user can change mind mid-operation)

# @example Usage in Regularize tool
#   def mp3d_cq_start_session
#     # ... triangulation, loop detection ...
#
#     # Create UV session (captures UV immediately)
#     all_vertices = @original_positions.keys
#     @uv_session = Shared::UVHelper::UVSession.new(all_vertices)
#
#     # Apply initial transformation (no restore yet)
#     mp3d_cq_apply_transformation(@last_intensity)
#
#     # Open dialog
#     mp3d_cq_create_dialog
#   end
#
#   # In dialog callbacks:
#   def on_preview(params)
#     intensity = params['intensity'].to_f / 100.0
#     mp3d_cq_apply_transformation(intensity)
#     # NO @uv_session.restore (performance during drag)
#   end
#
#   def on_update(params)
#     intensity = params['intensity'].to_f / 100.0
#     preserve_uv = params['preserve_uv']
#     mp3d_cq_apply_transformation(intensity)
#     @uv_session.restore(preserve_uv)  # Restore conditionally
#   end
#
#   def on_apply(params)
#     intensity = params['intensity'].to_f / 100.0
#     preserve_uv = params['preserve_uv']
#     mp3d_cq_apply_transformation(intensity)
#     @uv_session.restore(preserve_uv)  # Restore conditionally
#     commit_operation()
#   end
#
class UVSession
  
  # Initialize UV session.
  
  # CRITICAL CHANGE (FIX): UV data is ALWAYS captured, regardless of
  # preserve_uv parameter. This matches spherify_v1_7.rb proven logic.
  #
  # REASON:
  # The preserve_uv parameter reflects the INITIAL checkbox state,
  # but user can toggle checkbox at ANY time during tool operation.
  # If we only capture when preserve_uv=true, toggling checkbox later
  # has no effect (no UV data to restore).
  #
  # PREVIOUS BUGGY BEHAVIOR:
  # - User launches tool with checkbox unchecked
  # - UV data NOT captured (because preserve_uv=false)
  # - User checks checkbox during operation
  # - Restore does nothing (no UV data!)
  # - User frustrated
  #
  # NEW CORRECT BEHAVIOR (matching spherify_v1_7.rb):
  # - UV data ALWAYS captured at initialization
  # - restore() method accepts enable_flag parameter
  # - User can toggle checkbox and see immediate effect
  # - Matches proven spherify_v1_7.rb logic exactly
  #
  # PERFORMANCE:
  # UV capture is fast (< 50ms for typical meshes).
  # Always capturing has negligible performance impact.
  #
  # @param vertices [Array<Sketchup::Vertex>] Vertices whose connected
  #   faces should have UV data captured
  #
  # @example Create session at tool start
  #   vertices = edge_loop.flat_map(&:vertices).uniq
  #   @uv_session = Shared::UVHelper::UVSession.new(vertices)
  #
  def initialize(vertices)
    # ALWAYS capture UV data (matching spherify_v1_7.rb logic)
    # User can enable/disable restore later by passing flag to restore()
    @uv_data = UVHelper.capture_uv_data(vertices)
  end
  
  # Restore UV coordinates to faces.
  
  # Call this method after geometry transformation to restore textures.
  # Safe to call multiple times (idempotent).
  #
  # CRITICAL CHANGE (FIX): Now accepts optional enable parameter.
  # This allows conditional restoration based on checkbox state.
  #
  # REASON:
  # UV data is always captured at initialization (so user can toggle
  # checkbox mid-operation), but we only want to restore if checkbox
  # is currently checked.
  #
  # USAGE PATTERN (matching spherify_v1_7.rb):
  # - on_preview: DON'T call restore (performance)
  # - on_update: Call restore(preserve_uv_checkbox_state)
  # - on_apply: Call restore(preserve_uv_checkbox_state)
  #
  # When to call:
  # - On slider release (on_update callback)
  # - On Apply/OK button (on_apply callback)
  # - NOT during slider drag (on_preview callback) - performance reason
  #
  # @param enable [Boolean] Whether to actually restore UV data.
  #   If false, method returns immediately (no-op).
  #   If true (or omitted for backward compat), restores UV data.
  #   Default: true (for backward compatibility with existing code)
  #
  # @return [void]
  #
  # @example Restore conditionally based on checkbox
  #   def on_update(params)
  #     apply_transformation(params['intensity'])
  #     preserve_uv = params['preserve_uv']  # Current checkbox state
  #     @uv_session.restore(preserve_uv)     # Restore only if checked
  #   end
  #
  # @example Restore unconditionally (backward compat)
  #   @uv_session.restore  # Restores if has_data (old behavior)
  #
  def restore(enable = true)
    # If enable=false, do nothing (user unchecked checkbox)
    return unless enable
    
    # If no UV data captured, do nothing (no textured faces in selection)
    return if @uv_data.empty?
    
    # Restore UV data
    UVHelper.restore_uv_data(@uv_data)
  end
  
  # Check if session has captured UV data.
  
  # Returns false if no textured faces found in selection.
  #
  # @return [Boolean] true if UV data was captured
  #
  # @example Debug output
  #   if @uv_session.has_data?
  #     puts "UV data captured for #{@uv_session.face_count} faces"
  #   else
  #     puts "No textured faces in selection"
  #   end
  #
  def has_data?
    !@uv_data.empty?
  end
  
  # Get count of faces with captured UV data.
  
  # @return [Integer] Number of textured faces
  #
  # @example Status message
  #   count = @uv_session.face_count
  #   puts "UV preservation: #{count} textured face(s)" if count > 0
  #
  def face_count
    @uv_data.size
  end
  
end  # class UVSession

end  # module UVHelper
end  # module Shared
end  # module CurvyQuads
end  # module MarcelloPanicciaTools
