# frozen_string_literal: true

module MarcelloPanicciaTools
  module CurvyQuads
    # Catmull-Rom Aligner Tool - Phase A: Visual Validation
    #
    # This tool analyzes selected edges atomically per vertex, finds control points
    # (P0, P1, P2, P3), generates Centripetal Catmull-Rom splines, and visualizes
    # the analysis with colored construction points and curves.
    #
    # Phase A focuses on VISUALIZATION ONLY - no mesh modification.
    module CatmullRomAlignerTool
      # Main entry point: Analyze selection and visualize
      def self.analyze_selection
        model = Sketchup.active_model
        selection = model.selection

        # Validate selection
        selected_edges = selection.grep(Sketchup::Edge)
        if selected_edges.empty?
          ::UI.messagebox("Please select edges to analyze.\n\nSelect column edges of a quad mesh.")
          return
        end

        puts "\n" + "=" * 60
        puts "CATMULL-ROM ALIGNER - Phase A: Visual Analysis"
        puts "=" * 60
        puts "Selected edges: #{selected_edges.length}"

        # Extract all vertices from selected edges
        selected_vertices = TopologyNavigator.extract_vertices_from_edges(selected_edges)
        puts "Selected vertices: #{selected_vertices.size}"

        # Track processed vertices to avoid duplicate rows
        processed_vertices = Set.new
        row_count = 0
        valid_rows = 0

        model.start_operation('Catmull-Rom Analysis', true)

        begin
          # Create a diagnostic group to isolate all visualization geometry
          # This prevents interference with the user's mesh
          diagnostic_group = model.entities.add_group
          diagnostic_group.name = 'CatmullRom_Diagnostic'

          # Process each vertex atomically
          selected_vertices.each do |vertex|
            # Skip if already processed as part of another row
            next if processed_vertices.include?(vertex)

            # Analyze this vertex
            row_data = TopologyNavigator.analyze_vertex(vertex, selected_edges)

            # Skip if analysis failed (invalid topology)
            unless row_data
              puts "[Warning] Vertex #{vertex.entityID} - analysis failed (invalid topology)"
              processed_vertices.add(vertex)
              next
            end

            # Validate that we have minimum required data
            unless row_data[:P1] && row_data[:P2]
              puts "[Warning] Vertex #{vertex.entityID} - missing anchors P1/P2"
              processed_vertices.add(vertex)
              next
            end

            # Handle boundary cases (missing P0 or P3)
            row_data[:P0] ||= row_data[:P1]
            row_data[:P3] ||= row_data[:P2]

            # Generate Catmull-Rom spline
            p0 = row_data[:P0].position
            p1 = row_data[:P1].position
            p2 = row_data[:P2].position
            p3 = row_data[:P3].position

            num_samples = CatmullRomSpline.calculate_num_samples(
              p1, p2, row_data[:internal_vertices].length
            )
            spline_points = CatmullRomSpline.generate_points(p0, p1, p2, p3, num_samples: num_samples)

            # Visualize (inside diagnostic group to avoid mesh interference)
            DiagnosticVisualizer.visualize_row(row_data, spline_points, diagnostic_group.entities, valid_rows)

            # Mark all vertices in this row as processed
            processed_vertices.add(vertex)
            row_data[:internal_vertices].each { |v| processed_vertices.add(v) }

            valid_rows += 1
          end

          model.commit_operation

          puts "\n" + "-" * 60
          puts "ANALYSIS COMPLETE"
          puts "Total vertices processed: #{processed_vertices.size}"
          puts "Valid rows found: #{valid_rows}"
          puts "Diagnostic geometry created in layers:"
          DiagnosticVisualizer::LAYERS.each_value { |layer_name| puts "  - #{layer_name}" }
          puts "\nUse 'Catmull-Rom Aligner → Clear Debug Geometry' to cleanup."
          puts "=" * 60

          ::UI.messagebox(
            "Analysis complete!\n\n" \
            "Rows analyzed: #{valid_rows}\n" \
            "Vertices processed: #{processed_vertices.size}\n\n" \
            "Check Ruby Console for detailed report.\n" \
            "Diagnostic layers created:\n" \
            "  - #{DiagnosticVisualizer::LAYERS[:construction_points]}\n" \
            "  - #{DiagnosticVisualizer::LAYERS[:splines]}\n\n" \
            "Color legend:\n" \
            "  • Green spheres = P0/P3 (controls)\n" \
            "  • Red spheres = P1/P2 (anchors)\n" \
            "  • Blue spheres = Internal vertices\n" \
            "  • Yellow spheres = Target positions\n" \
            "  • Blue curves = Catmull-Rom splines"
          )

        rescue => e
          model.abort_operation
          puts "[Error] Analysis failed: #{e.message}"
          puts e.backtrace.join("\n")
          ::::UI.messagebox("Analysis failed: #{e.message}\n\nCheck Ruby Console for details.")
        end
      end

      # Cleanup all diagnostic geometry
      def self.clear_debug_geometry
        result = ::UI.messagebox(
          "This will remove all Catmull-Rom diagnostic geometry.\n\nContinue?",
          MB_YESNO
        )

        return unless result == IDYES

        DiagnosticVisualizer.cleanup_all
        ::UI.messagebox("Diagnostic geometry cleared.")
      end
    end
  end
end
