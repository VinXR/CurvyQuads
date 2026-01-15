# frozen_string_literal: true

module MarcelloPanicciaTools
  module CurvyQuads
    module CatmullRomSpline
      # Generates a Centripetal Catmull-Rom spline curve passing through P1 and P2,
      # using P0 and P3 as control points for tangent calculation.
      #
      # Centripetal parameterization (alpha = 0.5) prevents self-intersections
      # and cusps when control points are non-uniformly spaced.
      #
      # @param p0 [Geom::Point3d] Control point before curve start
      # @param p1 [Geom::Point3d] Curve start point (anchor)
      # @param p2 [Geom::Point3d] Curve end point (anchor)
      # @param p3 [Geom::Point3d] Control point after curve end
      # @param num_samples [Integer] Number of points to generate along curve
      # @param alpha [Float] Parameterization type (0.0=uniform, 0.5=centripetal, 1.0=chordal)
      # @return [Array<Geom::Point3d>] Array of points along the curve
      def self.generate_points(p0, p1, p2, p3, num_samples: 20, alpha: 0.5)
        # Calculate parametric values t0, t1, t2, t3
        t0 = 0.0
        t1 = calculate_t(t0, p0, p1, alpha)
        t2 = calculate_t(t1, p1, p2, alpha)
        t3 = calculate_t(t2, p2, p3, alpha)

        # Edge case: degenerate parameters
        return [p1, p2] if (t2 - t1).abs < 0.0001

        points = []

        # Generate num_samples points uniformly distributed in parameter space [t1, t2]
        (0...num_samples).each do |i|
          # Normalized parameter u ∈ [0, 1]
          u = i.to_f / (num_samples - 1)

          # Map to [t1, t2]
          t = t1 + u * (t2 - t1)

          # Evaluate curve at parameter t
          point = evaluate_at(p0, p1, p2, p3, t, t0, t1, t2, t3)
          points << point
        end

        points
      end

      # Calculates next parametric value using centripetal parameterization
      #
      # @param t_prev [Float] Previous t value
      # @param p_prev [Geom::Point3d] Previous point
      # @param p_curr [Geom::Point3d] Current point
      # @param alpha [Float] Parameterization exponent
      # @return [Float] Next t value
      def self.calculate_t(t_prev, p_prev, p_curr, alpha)
        distance = p_prev.distance(p_curr)

        # Avoid division by zero for coincident points
        return t_prev if distance < 0.0001

        t_prev + (distance**alpha)
      end

      # Evaluates the Catmull-Rom curve at parameter t using recursive interpolation
      #
      # Formula:
      #   A1(t) = lerp between P0 and P2
      #   A2(t) = lerp between P1 and P3
      #   B1(t) = lerp between A1 and P1
      #   B2(t) = lerp between P1 and A2
      #   C(t)  = lerp between B1 and B2 (final point on curve)
      #
      # @param p0 [Geom::Point3d] Control point 0
      # @param p1 [Geom::Point3d] Control point 1 (curve start)
      # @param p2 [Geom::Point3d] Control point 2 (curve end)
      # @param p3 [Geom::Point3d] Control point 3
      # @param t [Float] Parameter value to evaluate at (t ∈ [t1, t2])
      # @param t0 [Float] Parameter at P0
      # @param t1 [Float] Parameter at P1
      # @param t2 [Float] Parameter at P2
      # @param t3 [Float] Parameter at P3
      # @return [Geom::Point3d] Point on curve at parameter t
      def self.evaluate_at(p0, p1, p2, p3, t, t0, t1, t2, t3)
        # First level: A1 and A2
        a1 = lerp_point(p0, p2, t, t0, t2)
        a2 = lerp_point(p1, p3, t, t1, t3)

        # Second level: B1 and B2
        b1 = lerp_point(a1, p1, t, t0, t1)
        b2 = lerp_point(p1, a2, t, t2, t3)

        # Third level: C (final point)
        c = lerp_point(b1, b2, t, t1, t2)

        c
      end

      # Linear interpolation between two points based on parameter t
      #
      # @param p_start [Geom::Point3d] Start point
      # @param p_end [Geom::Point3d] End point
      # @param t [Float] Current parameter value
      # @param t_start [Float] Parameter at start point
      # @param t_end [Float] Parameter at end point
      # @return [Geom::Point3d] Interpolated point
      def self.lerp_point(p_start, p_end, t, t_start, t_end)
        # Handle degenerate case
        return p_start if (t_end - t_start).abs < 0.0001

        # Calculate weights
        w_start = (t_end - t) / (t_end - t_start)
        w_end = (t - t_start) / (t_end - t_start)

        # Weighted interpolation
        x = p_start.x * w_start + p_end.x * w_end
        y = p_start.y * w_start + p_end.y * w_end
        z = p_start.z * w_start + p_end.z * w_end

        Geom::Point3d.new(x, y, z)
      end

      # Calculates optimal number of samples based on curve length and density
      #
      # @param p1 [Geom::Point3d] Curve start
      # @param p2 [Geom::Point3d] Curve end
      # @param num_internal_vertices [Integer] Number of vertices to map onto curve
      # @return [Integer] Recommended number of samples
      def self.calculate_num_samples(p1, p2, num_internal_vertices)
        # Distance-based density: 1 sample every 2 inches
        distance = p1.distance(p2)
        samples_from_distance = (distance / 2.0).ceil

        # Minimum based on internal vertices + margin
        samples_from_vertices = num_internal_vertices + 10

        # Take maximum, with reasonable bounds
        num_samples = [samples_from_distance, samples_from_vertices, 10].max
        [num_samples, 100].min  # Cap at 100
      end
    end
  end
end
