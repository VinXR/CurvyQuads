# frozen_string_literal: true

module MarcelloPanicciaTools
  module CurvyQuads
    module DiagnosticVisualizer
      # Layer names for diagnostic geometry
      LAYERS = {
        construction_points: 'CatmullRom_Debug_CPoints',
        splines: 'CatmullRom_Debug_Splines',
        labels: 'CatmullRom_Debug_Labels'
      }.freeze

      # Color scheme for control points
      COLORS = {
        p0: Sketchup::Color.new(0, 128, 0),      # Dark green (control left)
        p1: Sketchup::Color.new(255, 0, 0),      # Red (anchor left)
        p2: Sketchup::Color.new(255, 0, 0),      # Red (anchor right)
        p3: Sketchup::Color.new(0, 128, 0),      # Dark green (control right)
        internal: Sketchup::Color.new(0, 100, 255), # Blue (vertices to move)
        target: Sketchup::Color.new(255, 200, 0),   # Yellow (target positions)
        spline: Sketchup::Color.new(0, 100, 255)    # Blue (spline curve)
      }.freeze

      # Visualizes a complete row analysis with control points, spline, and targets
      #
      # @param row_data [Hash] Analysis result from TopologyNavigator
      # @param spline_points [Array<Geom::Point3d>] Points along Catmull-Rom curve
      # @param entities [Sketchup::Entities] Where to add geometry
      # @param row_index [Integer] Row number for reporting
      def self.visualize_row(row_data, spline_points, entities, row_index)
        ensure_layers_exist

        # Create control points
        create_control_point(row_data[:P0], :p0, entities, "P0_#{row_index}") if row_data[:P0]
        create_control_point(row_data[:P1], :p1, entities, "P1_#{row_index}") if row_data[:P1]
        create_control_point(row_data[:P2], :p2, entities, "P2_#{row_index}") if row_data[:P2]
        create_control_point(row_data[:P3], :p3, entities, "P3_#{row_index}") if row_data[:P3]

        # Create internal vertex markers
        row_data[:internal_vertices].each_with_index do |vertex, idx|
          create_control_point(vertex, :internal, entities, "V#{row_index}_#{idx}")
        end

        # Create spline curve
        create_spline_curve(spline_points, entities)

        # Create target points and connection lines
        create_target_points(row_data, spline_points, entities)

        # Print diagnostic report
        print_row_report(row_data, row_index)
      end

      # Creates a colored construction point (using small sphere since SketchUp
      # doesn't support colored CPoints natively)
      #
      # @param vertex_or_position [Sketchup::Vertex, Geom::Point3d] Position
      # @param type [Symbol] Type of point (:p0, :p1, :p2, :p3, :internal, :target)
      # @param entities [Sketchup::Entities] Where to add geometry
      # @param label [String] Optional label for identification
      def self.create_control_point(vertex_or_position, type, entities, label = nil)
        position = vertex_or_position.is_a?(Sketchup::Vertex) ? vertex_or_position.position : vertex_or_position
        color = COLORS[type]

        # Create small sphere group
        group = entities.add_group
        layer = Sketchup.active_model.layers[LAYERS[:construction_points]]
        group.layer = layer

        # Sphere with radius 2 inches (visible but not invasive)
        circle = group.entities.add_circle(position, [0, 0, 1], 2.0, 12)
        face = group.entities.add_face(circle)
        face.pushpull(-4.0) if face

        # Apply color material
        material = get_or_create_material("CatmullRom_#{type}", color)
        group.entities.each do |entity|
          entity.material = material if entity.is_a?(Sketchup::Face)
        end

        # Optional text label
        if label
          text_position = position.offset([0, 0, 1], 6.0)
          text = entities.add_text(label, text_position)
          text.layer = Sketchup.active_model.layers[LAYERS[:labels]]
        end

        group
      end

      # Creates a Catmull-Rom spline curve in SketchUp
      #
      # @param points [Array<Geom::Point3d>] Points along curve
      # @param entities [Sketchup::Entities] Where to add curve
      # @return [Array<Sketchup::Edge>] Edges forming the curve
      def self.create_spline_curve(points, entities)
        return [] if points.length < 2

        # SketchUp's add_curve creates a smooth polyline
        curve_edges = entities.add_curve(points)
        layer = Sketchup.active_model.layers[LAYERS[:splines]]

        # Style the curve
        curve_edges.each do |edge|
          edge.layer = layer
          edge.material = COLORS[:spline]
          edge.soft = true
          edge.smooth = true
        end

        curve_edges
      end

      # Creates target points on the spline where internal vertices should be moved
      # and dashed lines connecting original vertices to targets
      #
      # @param row_data [Hash] Row analysis data
      # @param spline_points [Array<Geom::Point3d>] Points along curve
      # @param entities [Sketchup::Entities] Where to add geometry
      def self.create_target_points(row_data, spline_points, entities)
        internal_vertices = row_data[:internal_vertices]
        return if internal_vertices.empty?
        return if spline_points.length < 2

        # Distribute targets uniformly along spline (excluding first and last points)
        # We skip first and last because they are P1 and P2 (anchors)
        num_targets = internal_vertices.length
        step = (spline_points.length - 1).to_f / (num_targets + 1)

        internal_vertices.each_with_index do |vertex, idx|
          # Calculate target index on spline
          spline_idx = ((idx + 1) * step).round
          spline_idx = [[spline_idx, 1].max, spline_points.length - 2].min  # Clamp to valid range

          target_pos = spline_points[spline_idx]

          # Create yellow target marker
          create_control_point(target_pos, :target, entities)

          # Create dashed line from original vertex to target
          create_dashed_line(vertex.position, target_pos, entities)
        end
      end

      # Creates a dashed line between two points
      #
      # @param start_pos [Geom::Point3d] Start position
      # @param end_pos [Geom::Point3d] End position
      # @param entities [Sketchup::Entities] Where to add line
      def self.create_dashed_line(start_pos, end_pos, entities)
        edge = entities.add_line(start_pos, end_pos)
        layer = Sketchup.active_model.layers[LAYERS[:splines]]

        edge.layer = layer
        edge.material = COLORS[:target]
        edge.stipple = '-'  # Dashed line pattern
      end

      # Prints diagnostic report for a row to Ruby Console
      #
      # @param row_data [Hash] Row analysis data
      # @param row_index [Integer] Row number
      def self.print_row_report(row_data, row_index)
        puts "\n=== CATMULL-ROM ROW #{row_index} ==="
        puts "P0: #{row_data[:P0] ? format_point(row_data[:P0].position) : 'MISSING (boundary)'}"
        puts "P1 (anchor start): #{format_point(row_data[:P1].position)}"
        puts "P2 (anchor end): #{format_point(row_data[:P2].position)}"
        puts "P3: #{row_data[:P3] ? format_point(row_data[:P3].position) : 'MISSING (boundary)'}"
        puts "Internal vertices: #{row_data[:internal_vertices].length}"

        # Distance validation
        d_p1_p2 = row_data[:P1].position.distance(row_data[:P2].position)
        puts "Distance P1-P2: #{d_p1_p2.round(2)} inches"

        # Collinearity check
        if row_data[:P0] && row_data[:P3]
          v1 = (row_data[:P1].position - row_data[:P0].position).normalize
          v2 = (row_data[:P2].position - row_data[:P1].position).normalize
          dot = v1.dot(v2)
          status = dot.abs > 0.95 ? '(NEARLY STRAIGHT)' : ''
          puts "Collinearity P0-P1-P2: dot=#{dot.round(3)} #{status}"
        end
      end

      # Ensures diagnostic layers exist in the model
      def self.ensure_layers_exist
        model = Sketchup.active_model
        layers_manager = model.layers

        LAYERS.each_value do |layer_name|
          layers_manager.add(layer_name) unless layers_manager[layer_name]
        end
      end

      # Gets or creates a material with given name and color
      #
      # @param name [String] Material name
      # @param color [Sketchup::Color] Color
      # @return [Sketchup::Material] Material
      def self.get_or_create_material(name, color)
        model = Sketchup.active_model
        material = model.materials[name]

        unless material
          material = model.materials.add(name)
          material.color = color
        end

        material
      end

      # Removes all diagnostic geometry from the model
      def self.cleanup_all
        model = Sketchup.active_model

        model.start_operation('Cleanup Catmull-Rom Diagnostic', true)

        begin
          # Method 1: Delete diagnostic groups by name
          groups_to_delete = []
          model.entities.each do |entity|
            if entity.is_a?(Sketchup::Group) && entity.name == 'CatmullRom_Diagnostic'
              groups_to_delete << entity
            end
          end
          model.entities.erase_entities(groups_to_delete) unless groups_to_delete.empty?

          # Method 2: Delete all entities in diagnostic layers (fallback for old format)
          LAYERS.each_value do |layer_name|
            layer = model.layers[layer_name]
            next unless layer

            # Collect entities to delete
            entities_to_delete = []
            model.entities.each do |entity|
              entities_to_delete << entity if entity.layer == layer
            end

            # Delete them
            model.entities.erase_entities(entities_to_delete) unless entities_to_delete.empty?

            # Remove layer
            model.layers.remove(layer) if layer.entities.empty?
          end

          model.commit_operation
          puts "[CatmullRom] Diagnostic geometry cleaned up."
        rescue => e
          model.abort_operation
          puts "[CatmullRom] Cleanup failed: #{e.message}"
        end
      end

      # Formats a point for console output
      #
      # @param point [Geom::Point3d] Point to format
      # @return [String] Formatted string
      def self.format_point(point)
        "(#{point.x.round(2)}, #{point.y.round(2)}, #{point.z.round(2)})"
      end
    end
  end
end
