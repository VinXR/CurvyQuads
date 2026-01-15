# frozen_string_literal: true

#==============================================================================
# CurvyQuads - Settings Manager Module
#==============================================================================
# Module: SettingsManager
# Purpose: Global settings and default parameters for all tools
#
# Features:
# - Default parameter values for each tool
# - Toolbar button visibility configuration
# - Persistent storage using Sketchup.write_default
# - Extensible for future settings
#
# PDF Reference: Section 5 (Il Modulo "Settings")
#==============================================================================

module MarcelloPanicciaTools
  module CurvyQuads
    module Shared
      module SettingsManager
        extend self

        PREF_KEY = 'MarcelloPanicciaTools_CurvyQuads_Settings'

        #======================================================================
        # DEFAULT PARAMETERS (Per-Tool)
        #======================================================================

        # Default parameter values for each tool.
        #
        # Users can modify these via Settings dialog. Each tool queries
        # this registry at initialization to set its default values.
        #
        # @return [Hash] Default parameters: {tool_name => {param => value}}
        #
        # @note To add new tool, simply add entry here. No code changes needed.
        #
        def mp3d_cq_default_parameters
          {
            'regularize' => {
              'intensity' => 1.0,
              'preserve_uv' => false
            },
            'spherify_geometry' => {
              'amount' => 1.0,
              'radius_mult' => 1.0,
              'preserve_uv' => false
            },
            'spherify_objects' => {
              'amount' => 1.0,
              'radius_mult' => 1.0,
              'preserve_uv' => false
            },
            'set_flow' => {
              'intensity' => 1.0,
              'preserve_uv' => false
            }
            # FUTURE: Add new tools here
            # 'relax_topological' => {
            #   'strength' => 0.5,
            #   'iterations' => 3
            # }
          }
        end

        # Get default value for specific tool parameter.
        #
        # @param tool_name [String] Tool identifier (e.g., 'regularize')
        # @param param_name [String] Parameter name (e.g., 'intensity')
        # @return [Object] Default value, or nil if not found
        #
        # @example
        #   intensity = SettingsManager.mp3d_cq_get_default('regularize', 'intensity')
        #   # => 1.0
        #
        def mp3d_cq_get_default(tool_name, param_name)
          defaults = mp3d_cq_default_parameters
          return nil unless defaults[tool_name]
          defaults[tool_name][param_name]
        end

        # Set custom default value for tool parameter.
        #
        # Saves to persistent storage (survives SketchUp restart).
        #
        # @param tool_name [String] Tool identifier
        # @param param_name [String] Parameter name
        # @param value [Object] New default value
        # @return [void]
        #
        # @example
        #   SettingsManager.mp3d_cq_set_default('regularize', 'intensity', 0.8)
        #
        def mp3d_cq_set_default(tool_name, param_name, value)
          key = "#{PREF_KEY}_#{tool_name}_#{param_name}"
          Sketchup.write_default(PREF_KEY, key, value)
        end

        # Get custom default (if set) or fallback to hardcoded default.
        #
        # @param tool_name [String] Tool identifier
        # @param param_name [String] Parameter name
        # @return [Object] Custom or default value
        #
        def mp3d_cq_get_parameter(tool_name, param_name)
          key = "#{PREF_KEY}_#{tool_name}_#{param_name}"
          custom = Sketchup.read_default(PREF_KEY, key)
          return custom unless custom.nil?

          # Fallback to hardcoded default
          mp3d_cq_get_default(tool_name, param_name)
        end

        # Reset tool to hardcoded defaults.
        #
        # @param tool_name [String] Tool identifier
        # @return [void]
        #
        def mp3d_cq_reset_tool_defaults(tool_name)
          defaults = mp3d_cq_default_parameters[tool_name]
          return unless defaults

          defaults.each do |param_name, _|
            key = "#{PREF_KEY}_#{tool_name}_#{param_name}"
            Sketchup.write_default(PREF_KEY, key, nil)
          end
        end

        #======================================================================
        # TOOLBAR VISIBILITY
        #======================================================================

        # Default toolbar button visibility.
        #
        # Users can hide buttons they don't use. Toolbar Manager queries
        # this registry when building toolbar.
        #
        # @return [Hash] Button visibility: {button_id => visible}
        #
        def mp3d_cq_default_toolbar_visibility
          {
            'regularize' => true,
            'spherify_geometry' => true,
            'spherify_objects' => true,
            'set_flow' => true,
            'settings' => true,
            'documentation' => true
            # FUTURE: Add new buttons here
          }
        end

        # Check if toolbar button should be visible.
        #
        # @param button_id [String] Button identifier
        # @return [Boolean] true if visible
        #
        def mp3d_cq_button_visible?(button_id)
          key = "#{PREF_KEY}_toolbar_#{button_id}"
          saved = Sketchup.read_default(PREF_KEY, key)
          return saved unless saved.nil?

          # Fallback to default
          mp3d_cq_default_toolbar_visibility[button_id] || true
        end

        # Set toolbar button visibility.
        #
        # @param button_id [String] Button identifier
        # @param visible [Boolean] Visibility state
        # @return [void]
        #
        def mp3d_cq_set_button_visibility(button_id, visible)
          key = "#{PREF_KEY}_toolbar_#{button_id}"
          Sketchup.write_default(PREF_KEY, key, visible)
        end

        # Reset toolbar to default visibility.
        #
        # @return [void]
        #
        def mp3d_cq_reset_toolbar_visibility
          mp3d_cq_default_toolbar_visibility.each_key do |button_id|
            key = "#{PREF_KEY}_toolbar_#{button_id}"
            Sketchup.write_default(PREF_KEY, key, nil)
          end
        end

        #======================================================================
        # LICENSING (Future Integration)
        #======================================================================

        # Check if feature is licensed.
        #
        # Placeholder for future Sketchucation licensing integration.
        # Currently returns true for all features (free/beta mode).
        #
        # @param feature_name [String] Feature identifier
        # @return [Boolean] true if licensed (always true for now)
        #
        # @note FUTURE: Integrate with Sketchucation Licensing Tools
        #   Example:
        #     SketchucationLicense.validate('curvyquads_pro')
        #
        def mp3d_cq_licensed?(feature_name)
          # TODO: Implement licensing check when ready
          # For now, all features are free (beta/development)
          true
        end

      end # module SettingsManager
    end # module Shared
  end # module CurvyQuads
end # module MarcelloPanicciaTools
