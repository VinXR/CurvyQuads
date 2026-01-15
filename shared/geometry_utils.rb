# frozen_string_literal: true

#==============================================================================
# CurvyQuads - Geometry Utilities Module
#==============================================================================
# Module: GeometryUtils
# Purpose: Geometric calculations and transformations
#
# Features:
# - Best-fit circle calculation (3D) - VALIDATED from regularize_beta_02_0.rb
# - Circle point generation with coordinate system alignment
# - Bounding box calculations
# - Triangulation (QFT Convention) - Added Session Spherify
# - Vector operations
#
# Algorithm Source: regularize_beta_02_0.rb (calculate_circle_points method)
# This algorithm is PROVEN and must not be modified.
#
# PDF Reference: Section 7 (Geometry Helpers)
#==============================================================================

module MarcelloPanicciaTools
module CurvyQuads
module Shared
module GeometryUtils
  extend self

  #======================================================================
  # BEST-FIT CIRCLE (3D) - From Regularize Beta
  #======================================================================
  
  # Calculate centroid of points.
  #
  # @param points [Array<Geom::Point3d>] Input points
  # @return [Geom::Point3d] Centroid (geometric center)
  #
  def mp3d_cq_calculate_centroid(points)
    pt = Geom::Point3d.new(0, 0, 0)
    points.each { |p| pt = pt + p.to_a }
    pt.x /= points.size
    pt.y /= points.size
    pt.z /= points.size
    pt
  end

  # Calculate average radius from points to centroid.
  #
  # @param points [Array<Geom::Point3d>] Input points
  # @param centroid [Geom::Point3d] Circle center
  # @return [Float] Average radius
  #
  def mp3d_cq_calculate_average_radius(points, centroid)
    total_dist = points.reduce(0) { |sum, pt| sum + pt.distance(centroid) }
    total_dist / points.size
  end

  # Calculate best-fit normal using Newell's method.
  #
  # This is a robust method for calculating plane normal from
  # potentially non-planar point sets. More stable than simple cross product.
  #
  # @param points [Array<Geom::Point3d>] Input points
  # @return [Geom::Vector3d] Normal vector (normalized)
  #
  def mp3d_cq_calculate_best_fit_normal(points)
    # Newell's method approximation for robustness with non-planar loops
    normal = Geom::Vector3d.new(0, 0, 0)
    points.each_with_index do |curr, i|
      next_pt = points[(i + 1) % points.size]
      normal.x += (curr.y - next_pt.y) * (curr.z + next_pt.z)
      normal.y += (curr.z - next_pt.z) * (curr.x + next_pt.x)
      normal.z += (curr.x - next_pt.x) * (curr.y + next_pt.y)
    end
    normal.length == 0 ? Geom::Vector3d.new(0, 0, 1) : normal.normalize
  end

  # Calculate circle points with proper coordinate system alignment.
  #
  # This is the EXACT algorithm from regularize_beta_02_0.rb.
  # It ensures the circle aligns with the first point to minimize twisting.
  #
  # @param count [Integer] Number of points to generate
  # @param centroid [Geom::Point3d] Circle center
  # @param radius [Float] Circle radius
  # @param normal [Geom::Vector3d] Plane normal
  # @param first_point_ref [Geom::Point3d] First point in original loop (for alignment)
  # @return [Array<Geom::Point3d>] Array of points on circle perimeter
  #
  def mp3d_cq_calculate_circle_points(count, centroid, radius, normal, first_point_ref)
    # Coordinate system on the best-fit plane
    z_axis = normal
    
    # Stable X-axis calculation
    if (z_axis.x.abs < 0.5) && (z_axis.y.abs < 0.5)
      x_axis = z_axis.cross(Geom::Vector3d.new(1, 0, 0)).normalize
    else
      x_axis = z_axis.cross(Geom::Vector3d.new(0, 0, 1)).normalize
    end
    
    y_axis = z_axis.cross(x_axis).normalize
    
    # Calculate start angle to align with the first vertex (minimizes twisting)
    vec_to_first = first_point_ref - centroid
    
    # Project vec_to_first onto the plane to get accurate angle
    start_angle = Math.atan2(vec_to_first % y_axis, vec_to_first % x_axis)
    step_angle = (2 * Math::PI) / count
    
    new_points = []
    count.times do |i|
      angle = start_angle + (i * step_angle)
      px = centroid.x + radius * Math.cos(angle) * x_axis.x + radius * Math.sin(angle) * y_axis.x
      py = centroid.y + radius * Math.cos(angle) * x_axis.y + radius * Math.sin(angle) * y_axis.y
      pz = centroid.z + radius * Math.cos(angle) * x_axis.z + radius * Math.sin(angle) * y_axis.z
      new_points << Geom::Point3d.new(px, py, pz)
    end
    
    new_points
  end

  #======================================================================
  # BOUNDING BOX
  #======================================================================
  
  # Calculate bounding box for vertices.
  #
  # Creates a Geom::BoundingBox that encompasses all given vertices.
  # Useful for calculating object dimensions and centers.
  #
  # @param vertices [Array<Sketchup::Vertex>] Input vertices
  # @return [Geom::BoundingBox] Bounding box
  #
  def mp3d_cq_calculate_bounding_box(vertices)
    bb = Geom::BoundingBox.new
    vertices.each { |v| bb.add(v.position) }
    bb
  end

  #======================================================================
  # TRIANGULATION (QFT Convention)
  #======================================================================
  
  # Triangulate faces using QuadFace Tools convention.
  #
  # Applies explicit triangulation to prevent autofold and ensure stable topology:
  # - Quads (4 vertices): Diagonal edge (verts[0] → verts[2]) with soft=true, smooth=true, casts_shadows=false
  # - N-gons (5+ vertices): Fan triangulation from verts[0] with soft=true, smooth=true, casts_shadows=true
  #
  # QFT Convention:
  # - Quad diagonals marked with casts_shadows=false (topology flag)
  # - Regular triangulation edges have casts_shadows=true
  #
  # CRITICAL: Must be called BEFORE UV capture to ensure stable vertex order.
  #
  # Why This Matters:
  # - Prevents autofold (SketchUp's automatic face splitting is unpredictable)
  # - Stabilizes vertex order (essential for UV preservation)
  # - Maintains QFT compatibility (TopologyAnalyzer recognizes quads)
  # - Enables soft selection (requires stable topology)
  #
  # Algorithm Source: regularize_tool.rb (mp3d_cq_triangulate_faces)
  # Used by: Regularize, Spherify Geometry, Spherify Objects, Set Flow
  #
  # @param entities [Sketchup::Entities] Entity collection to triangulate
  # @param faces [Array<Sketchup::Face>, nil] Faces to triangulate (if nil, uses all faces in entities)
  # @return [Hash] Statistics {:quads => N, :ngons => M, :edges_added => K}
  #
  # @example Triangulate selection
  #   selection_faces = model.selection.grep(Sketchup::Face)
  #   stats = GeometryUtils.mp3d_cq_triangulate_faces(model.active_entities, selection_faces)
  #   puts "Added #{stats[:edges_added]} edges"
  #
  # @example Triangulate all faces in context
  #   stats = GeometryUtils.mp3d_cq_triangulate_faces(group.entities, nil)
  #   puts "Processed #{stats[:quads]} quads and #{stats[:ngons]} n-gons"
  #
  def self.mp3d_cq_triangulate_faces(entities, faces = nil)
    # If faces not provided, use all faces in entities
    faces = faces.nil? ? entities.grep(Sketchup::Face) : faces
    
    # Statistics counters
    quads_count = 0
    ngons_count = 0
    edges_added = 0
    
    faces.each do |face|
      next unless face.valid?
      
      verts = face.vertices
      vert_count = verts.size
      
      # Quads: diagonal (soft + smooth + no shadows)
      # QFT Convention: casts_shadows = false marks this as quad diagonal
      if vert_count == 4
        begin
          edge = entities.add_line(verts[0], verts[2])
          if edge
            edge.soft = true
            edge.smooth = true
            edge.casts_shadows = false  # QFT diagonal marker
            edges_added += 1
            quads_count += 1
          end
        rescue
          # Edge already exists (skip silently)
        end
        
      # N-gons: fan triangulation (soft + smooth + cast shadows)
      # Regular triangulation edges (NOT quad diagonals)
      elsif vert_count > 4
        v0 = verts[0]
        (2..(vert_count - 2)).each do |i|
          begin
            edge = entities.add_line(v0, verts[i])
            if edge
              edge.soft = true
              edge.smooth = true
              edge.casts_shadows = true  # Regular triangulation
              edges_added += 1
            end
          rescue
            # Edge already exists (skip silently)
          end
        end
        ngons_count += 1
      end
    end
    
    # Return statistics
    { quads: quads_count, ngons: ngons_count, edges_added: edges_added }
  end

  #======================================================================
  # VECTOR OPERATIONS
  #======================================================================
  
  # Linear interpolation between two points.
  #
  # Interpolates between point_a and point_b using parameter t:
  # - t = 0.0 returns point_a
  # - t = 1.0 returns point_b
  # - t = 0.5 returns midpoint
  #
  # @param point_a [Geom::Point3d] Start point
  # @param point_b [Geom::Point3d] End point
  # @param t [Float] Interpolation factor (0.0 = A, 1.0 = B)
  # @return [Geom::Point3d] Interpolated point
  #
  # @example
  #   # Get point 30% of the way from A to B
  #   midpoint = GeometryUtils.mp3d_cq_lerp(point_a, point_b, 0.3)
  #
  def mp3d_cq_lerp(point_a, point_b, t)
    Geom::Point3d.new(
      point_a.x + (point_b.x - point_a.x) * t,
      point_a.y + (point_b.y - point_a.y) * t,
      point_a.z + (point_b.z - point_a.z) * t
    )
  end

end # module GeometryUtils
end # module Shared
end # module CurvyQuads
end # module MarcelloPanicciaTools
