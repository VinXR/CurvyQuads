# frozen_string_literal: true

#==============================================================================
# CurvyQuads - Toolbar Manager
#==============================================================================
# Module: ToolbarManager
# Purpose: Creates and manages the CurvyQuads toolbar with 7 buttons
#
# Toolbar Buttons (left to right):
# 1. Regularize
# 2. Spherify Geometry
# 3. Spherify Objects
# 4. Set Flow
# 5. Catmull-Rom Aligner
# 6. Settings
# 7. Documentation
#
# Features:
# - Configurable button visibility (via Settings dialog)
# - Persistent toolbar state (show/hide survives restart)
# - Icon paths ready for future icon files
#
# PDF Reference: Section 4A (Toolbar Principale)
#==============================================================================

module MarcelloPanicciaTools
  module CurvyQuads
    module UI
      module ToolbarManager
        extend self

        TOOLBAR_NAME = 'CurvyQuads'

        # Create and populate toolbar.
        #
        # @return [UI::Toolbar] The created toolbar
        #
        def mp3d_cq_create_toolbar
          toolbar = ::UI::Toolbar.new(TOOLBAR_NAME)

          # Button 1: Regularize
          if mp3d_cq_button_visible?('regularize')
            cmd_regularize = mp3d_cq_create_command(
              'Regularize',
              'Transform edge loops into perfect circles',
              'regularize' # Icon filename (without extension)
            ) { Tools::RegularizeTool.activate }
            toolbar.add_item(cmd_regularize)
          end

          # Button 2: Spherify Geometry
          if mp3d_cq_button_visible?('spherify_geometry')
            cmd_spherify_geo = mp3d_cq_create_command(
              'Spherify Geometry',
              'Spherical deformation for raw geometry (requires edit context)',
              'spherify_geometry'
            ) { Tools::SpherifyGeometryTool.activate }
            toolbar.add_item(cmd_spherify_geo)
          end

          # Button 3: Spherify Objects
          if mp3d_cq_button_visible?('spherify_objects')
            cmd_spherify_obj = mp3d_cq_create_command(
              'Spherify Objects',
              'Spherical deformation for Groups and Components',
              'spherify_objects'
            ) { Tools::SpherifyObjectsTool.activate }
            toolbar.add_item(cmd_spherify_obj)
          end

          # Button 4: Set Flow
          if mp3d_cq_button_visible?('set_flow')
            cmd_set_flow = mp3d_cq_create_command(
              'Set Flow',
              'Conform edge loops to adjacent curvature',
              'set_flow'
            ) { Tools::SetFlowTool.activate }
            toolbar.add_item(cmd_set_flow)
          end

          # Button 5: Catmull-Rom Aligner
          if mp3d_cq_button_visible?('catmullrom_aligner')
            cmd_catmullrom = mp3d_cq_create_command(
              'Catmull-Rom Aligner',
              'Align vertices along Catmull-Rom curves (Phase A: Visual Analysis)',
              'catmullrom_aligner'
            ) { CatmullRomAlignerTool.analyze_selection }
            toolbar.add_item(cmd_catmullrom)
          end

          # Button 6: Settings
          if mp3d_cq_button_visible?('settings')
            cmd_settings = mp3d_cq_create_command(
              'Settings',
              'Configure CurvyQuads preferences and defaults',
              'settings'
            ) { UI::SettingsDialog.show }
            toolbar.add_item(cmd_settings)
          end

          # Button 7: Documentation
          if mp3d_cq_button_visible?('documentation')
            cmd_docs = mp3d_cq_create_command(
              'Documentation',
              'View help, tutorials, and known issues',
              'documentation'
            ) { UI::DocumentationDialog.show }
            toolbar.add_item(cmd_docs)
          end

          # Show toolbar if it was visible in last session
          toolbar.show if mp3d_cq_toolbar_was_visible?
          toolbar
        end

        # Create UI command with icon support.
        #
        # @param name [String] Command name
        # @param tooltip [String] Tooltip text
        # @param icon_name [String] Icon filename (without extension)
        # @yield Block to execute when command is triggered
        # @return [UI::Command] The created command
        #
        # @note Icon files should be placed in:
        #   - Small (16x16): CurvyQuads/icons/#{icon_name}_16.png
        #   - Large (24x24): CurvyQuads/icons/#{icon_name}_24.png
        #   If icons don't exist, toolbar will show text labels
        #
        def mp3d_cq_create_command(name, tooltip, icon_name, &block)
          cmd = ::UI::Command.new(name, &block)
          cmd.tooltip = tooltip
          cmd.status_bar_text = tooltip

          # Set icons (if available)
          icon_path = File.join(CurvyQuads::PLUGIN_ROOT, 'icons')
          small_icon = File.join(icon_path, "#{icon_name}_16.png")
          large_icon = File.join(icon_path, "#{icon_name}_24.png")

          if File.exist?(small_icon)
            cmd.small_icon = small_icon
            cmd.large_icon = large_icon if File.exist?(large_icon)
          end

          cmd
        end

        # Check if button should be visible.
        #
        # @param button_id [String] Button identifier
        # @return [Boolean] true if visible
        #
        def mp3d_cq_button_visible?(button_id)
          Shared::SettingsManager.mp3d_cq_button_visible?(button_id)
        end

        # Check if toolbar was visible in last session.
        #
        # @return [Boolean] true if was visible
        #
        def mp3d_cq_toolbar_was_visible?
          Sketchup.read_default(CurvyQuads::PREF_NAMESPACE, 'toolbar_visible', true)
        end

        # Save toolbar visibility state.
        #
        # @param visible [Boolean] Visibility state
        # @return [void]
        #
        def mp3d_cq_save_toolbar_state(visible)
          Sketchup.write_default(CurvyQuads::PREF_NAMESPACE, 'toolbar_visible', visible)
        end

      end # module ToolbarManager
    end # module UI
  end # module CurvyQuads
end # module MarcelloPanicciaTools
