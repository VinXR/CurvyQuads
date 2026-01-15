# frozen_string_literal: true

#==============================================================================
# CurvyQuads - UI Manager (Dialog Base Class)
#==============================================================================
# Module: DialogBase
# Purpose: Reusable base class for all tool dialogs with standardized UI
#
# This is the foundation for all 4 tool dialogs (Regularize, Spherify Geometry,
# Spherify Objects, Set Flow). It provides:
# - Automatic HTML generation from control config
# - Standardized button layout (Reset, Cancel, OK)
# - Event handling (preview, update, apply, cancel, reset)
# - Window position persistence
# - Control state management
#
# Architecture Pattern (Template Method):
# ---------------------------------------
# DialogBase is an abstract base class. Tool-specific dialogs inherit from it
# and implement abstract methods:
# - control_config: Define sliders, checkboxes, etc.
# - on_preview: Handle live preview during slider drag
# - on_update: Handle final update on slider release
# - on_apply: Handle Apply/OK button
# - on_cancel: Handle Cancel/X button
#
# Event Flow (Critical for UV Preservation):
# ------------------------------------------
# JavaScript distinguishes between TWO slider events:
# 1. 'input' event: Fired continuously while dragging slider
#    → Calls on_preview(params)
#    → Tool updates geometry WITHOUT restoring UV (performance)
#    → Texture may appear distorted temporarily (expected)
#
# 2. 'change' event: Fired once when slider is released
#    → Calls on_update(params)
#    → Tool updates geometry AND restores UV
#    → Texture is corrected when user stops dragging
#
# This pattern matches Spherify v1.7 proven implementation and ensures:
# - Smooth real-time preview (no UV overhead during drag)
# - Correct textures when user finishes adjustment
# - Good performance even on complex meshes
#
# Button Behaviors:
# -----------------
# Reset Button:
# - Loads user defaults from SettingsManager (NOT factory defaults)
# - If user has saved custom defaults in Settings Dialog: use those
# - If no custom defaults: fallback to factory defaults
# - Callback: get_user_defaults() (implemented by subclass)
#
# Cancel Button:
# - Aborts operation (restores geometry to pre-tool state)
# - Closes dialog
# - Returns to selection tool
# - Callback: on_cancel()
#
# OK/Apply Button:
# - Commits operation (adds to undo stack)
# - Restores UV if enabled
# - Closes dialog
# - Returns to selection tool
# - Callback: on_apply(params)
#
# Enter Key:
# - Same behavior as OK/Apply button
# - Commits operation and closes tool
# - Callback: on_apply(params)
#
# Window Position:
# ---------------
# Each dialog remembers its last position per tool (stored in SketchUp preferences).
# Position is restored on next open. Default position: (800, 100) if never opened before.
#
# Control Types Supported:
# ------------------------
# - :slider (min, max, default, divisor for float conversion)
# - :checkbox (default true/false)
# - More types can be added in future (spinbox, dropdown, etc.)
#
# Usage Example (Tool Developer):
# -------------------------------
# class MyToolDialog < Shared::DialogBase
#   def initialize(tool)
#     super('My Tool', 'CurvyQuads_MyTool')
#     @tool = tool
#   end
#
#   def control_config
#     [
#       {type: :slider, id: 'intensity', label: 'Intensity', min: 0, max: 100, default: 100, divisor: 100},
#       {type: :checkbox, id: 'preserve_uv', label: 'Preserve UV', default: false}
#     ]
#   end
#
#   def on_preview(params)
#     @tool.apply_transformation(params['intensity'].to_f / 100.0)
#     # NO UV restore (performance)
#   end
#
#   def on_update(params)
#     @tool.apply_transformation(params['intensity'].to_f / 100.0)
#     @tool.uv_session.restore # Restore UV on slider release
#   end
#
#   def on_apply(params)
#     @tool.apply_transformation(params['intensity'].to_f / 100.0)
#     @tool.uv_session.restore # Restore UV before commit
#     @tool.commit_operation()
#   end
#
#   def on_cancel
#     @tool.abort_operation()
#   end
# end
#
# PDF Reference: Section 7C (UI System)
#==============================================================================
module MarcelloPanicciaTools
  module CurvyQuads
    module Shared
      # Base class for tool dialogs with standardized UI.
      #
      # All tool dialogs (Regularize, Spherify Geometry, Spherify Objects, Set Flow)
      # inherit from this class to ensure consistent behavior and appearance.
      #
      # Subclasses must implement abstract methods:
      # - control_config: Define UI controls
      # - on_preview: Handle live preview (slider drag)
      # - on_update: Handle final update (slider release)
      # - on_apply: Handle Apply/OK button
      # - on_cancel: Handle Cancel/X button
      #
      # @abstract Subclass and override abstract methods
      class DialogBase
        attr_reader :dialog, :is_active

        # Initialize dialog base.
        #
        # Sets up dialog infrastructure and loads last window position.
        #
        # @param tool_name [String] Display name for dialog title
        # @param pref_key [String] Unique preference key for storing window position
        #   Format: 'CurvyQuads_ToolName' (e.g., 'CurvyQuads_RegularizeTool')
        #
        # @example In subclass constructor
        #   def initialize(tool)
        #     super('Regularize', 'CurvyQuads_RegularizeTool')
        #     @tool = tool
        #   end
        def initialize(tool_name, pref_key)
          @tool_name = tool_name
          @pref_key = pref_key
          @dialog = nil
          @is_active = false
          @closing = false
        end

        #======================================================================
        # ABSTRACT METHODS (Must be implemented by subclass)
        #======================================================================

        # Define control configuration.
        #
        # Subclass must return array of control definitions.
        # Each control is a hash with keys: type, id, label, min, max, default, etc.
        #
        # Supported control types:
        # - :slider (requires: id, label, min, max, default, divisor)
        # - :checkbox (requires: id, label, default)
        #
        # @return [Array] Control definitions
        #
        # @example Slider and checkbox
        #   def control_config
        #     [
        #       {
        #         type: :slider,
        #         id: 'intensity',
        #         label: 'Intensity',
        #         min: 0,
        #         max: 100,
        #         default: 100,
        #         divisor: 100 # Convert to 0.0-1.0 range
        #       },
        #       {
        #         type: :checkbox,
        #         id: 'preserve_uv',
        #         label: 'Preserve UV Coordinates',
        #         default: false
        #       }
        #     ]
        #   end
        #
        # @abstract
        def control_config
          raise NotImplementedError, "#{self.class} must implement control_config"
        end

        # Handle preview update (live preview during slider drag).
        #
        # Called continuously while user drags slider.
        # Should update geometry WITHOUT restoring UV (performance optimization).
        #
        # @param params [Hash] Parameter values from dialog
        #   Keys are control IDs (strings), values are current values
        #   - Slider: String "0" to "max"
        #   - Checkbox: Boolean true/false
        #
        # @return [void]
        #
        # @example Preview without UV restore
        #   def on_preview(params)
        #     intensity = params['intensity'].to_f / 100.0
        #     @tool.apply_transformation(intensity)
        #     # NO UV restore here (performance)
        #   end
        #
        # @abstract
        def on_preview(params)
          raise NotImplementedError, "#{self.class} must implement on_preview"
        end

        # Handle update (slider release).
        #
        # Called once when user releases slider after dragging.
        # Should update geometry AND restore UV.
        #
        # @param params [Hash] Parameter values
        # @return [void]
        #
        # @example Update with UV restore
        #   def on_update(params)
        #     intensity = params['intensity'].to_f / 100.0
        #     @tool.apply_transformation(intensity)
        #     @tool.uv_session.restore # Restore UV on release
        #   end
        #
        # @abstract
        def on_update(params)
          raise NotImplementedError, "#{self.class} must implement on_update"
        end

        # Handle apply button (OK/Apply).
        #
        # Should commit operation, restore UV, and cleanup.
        #
        # @param params [Hash] Parameter values
        # @return [void]
        #
        # @example Apply with commit
        #   def on_apply(params)
        #     intensity = params['intensity'].to_f / 100.0
        #     @tool.apply_transformation(intensity)
        #     @tool.uv_session.restore # Restore UV before commit
        #     @tool.commit_operation()
        #   end
        #
        # @abstract
        def on_apply(params)
          raise NotImplementedError, "#{self.class} must implement on_apply"
        end

        # Handle cancel button (Cancel/X).
        #
        # Should abort operation and cleanup.
        #
        # @return [void]
        #
        # @example Cancel with abort
        #   def on_cancel
        #     @tool.abort_operation()
        #   end
        #
        # @abstract
        def on_cancel
          raise NotImplementedError, "#{self.class} must implement on_cancel"
        end

        #======================================================================
        # OPTIONAL HOOK (Override if needed)
        #======================================================================

        # Get user defaults for Reset button.
        #
        # Called when user clicks Reset button.
        # Should return Hash of control IDs => user default values.
        #
        # Default implementation reads from SettingsManager.
        # Override if tool has custom default logic.
        #
        # @return [Hash] User default values
        #   Keys: Control IDs (strings)
        #   Values: Default values in dialog units (e.g., 0-100 for slider)
        #
        # @example Default implementation (reads from SettingsManager)
        #   def get_user_defaults
        #     tool_key = 'regularize' # Tool identifier in SettingsManager
        #     {
        #       'intensity' => (SettingsManager.get_parameter(tool_key, 'intensity') * 100).to_i,
        #       'preserve_uv' => SettingsManager.get_parameter(tool_key, 'preserve_uv')
        #     }
        #   end
        def get_user_defaults
          defaults = {}
          control_config.each do |ctrl|
            defaults[ctrl[:id]] = ctrl[:default]
          end
          defaults
        end

        # Handle dialog closed event.
        #
        # Called when dialog is closed (via X button or programmatically).
        # Subclass can override for custom cleanup.
        #
        # @return [void]
        def on_dialog_closed
          # Subclass can override for custom cleanup
        end

        #======================================================================
        # PUBLIC API (Called by tool)
        #======================================================================

        # Create and show dialog.
        #
        # Generates HTML from control_config, sets up JavaScript callbacks,
        # and displays dialog at last remembered position.
        #
        # @return [void]
        #
        # @example In tool
        #   @dialog = MyToolDialog.new(self)
        #   @dialog.create_dialog
        def create_dialog
          return if @dialog

          config = control_config

          # Dialog dimensions
          width = 266

          # DYNAMIC HEIGHT CALCULATION (empirical tuning)
          # Base: 161px (Regularize with 1 slider - perfect fit)
          # Per extra slider: +48px (empirical value for compact spacing)
          num_sliders = config.count { |c| c[:type] == :slider }
          height = 161 + ((num_sliders - 1) * 48)

          # Load last window position from preferences
          last_x = ::Sketchup.read_default(@pref_key, 'window_x', 800)
          last_y = ::Sketchup.read_default(@pref_key, 'window_y', 100)

          options = {
            dialog_title: @tool_name,
            preferences_key: @pref_key,
            scrollable: false,
            resizable: false,
            width: width,
            height: height,
            left: last_x,
            top: last_y,
            style: ::UI::HtmlDialog::STYLE_DIALOG
          }

          @dialog = ::UI::HtmlDialog.new(options)
          @dialog.set_html(build_html)
          register_callbacks

          @dialog.set_on_closed do
            next if @closing
            on_dialog_closed
          end

          @dialog.show
          @is_active = true
          @closing = false
        end

        # Close dialog.
        #
        # Saves window position and closes dialog.
        # Safe to call even if dialog is already closed.
        #
        # @return [void]
        def close_dialog
          return unless @dialog

          @closing = true
          save_window_position
          @dialog.close
          @dialog = nil
          @is_active = false
        end

        #======================================================================
        # PRIVATE METHODS (Internal implementation)
        #======================================================================
        private

        # Build complete HTML document.
        #
        # Generates HTML with:
        # - CSS styles (ORIGINAL: white control boxes on gray background)
        # - Control elements (sliders, checkboxes)
        # - Buttons (Reset, Cancel, OK)
        # - JavaScript event handlers
        #
        # HTML is generated dynamically from control_config.
        # Cache buster in script tag ensures fresh JavaScript on reload.
        #
        # @return [String] Complete HTML document
        def build_html
          config = control_config
          controls_html = config.map { |ctrl| build_control_html(ctrl) }.join("\n")
          cache_buster = ::Time.now.to_i

          <<-HTML
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
      font-size: 11px;
      background-color: #f0f0f0;
      padding: 6px;
      overflow: hidden;
    }
    .control-group {
      background: white;
      border: 1px solid #ccc;
      border-radius: 4px;
      padding: 3px 6px;
      margin-bottom: 4px;
    }
    .control-group label {
      display: block;
      font-weight: 500;
      margin-bottom: 2px;
      color: #333;
    }
    .slider-container {
      display: flex;
      align-items: center;
      gap: 6px;
    }
    input[type="range"] {
      flex: 1;
      height: 18px;
    }
    .slider-value {
      min-width: 32px;
      text-align: right;
      font-variant-numeric: tabular-nums;
      color: #666;
    }
    .checkbox-container {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 2px 0;
    }
    .checkbox-container input[type="checkbox"] {
      margin: 0;
    }
    .checkbox-container label {
      margin: 0;
      font-weight: normal;
      cursor: pointer;
    }
    .button-row {
      display: flex;
      gap: 4px;
      margin-top: 10px;
    }
    button {
      flex: 1;
      padding: 6px 12px;
      font-size: 11px;
      border: 1px solid #999;
      border-radius: 4px;
      background: linear-gradient(to bottom, #fafafa, #e8e8e8);
      cursor: pointer;
      font-weight: 500;
    }
    button:hover {
      background: linear-gradient(to bottom, #f0f0f0, #d8d8d8);
    }
    button:active {
      background: #d0d0d0;
    }
    #btn-apply {
      background: linear-gradient(to bottom, #5a9fd4, #4285c8);
      color: white;
      border-color: #3275b8;
    }
    #btn-apply:hover {
      background: linear-gradient(to bottom, #4a8fc4, #3275b8);
    }
    #btn-apply:active {
      background: #2a6da8;
    }
  </style>
</head>
<body>
  #{controls_html}
  <div class="button-row">
    <button id="btn-reset">Reset</button>
    <button id="btn-cancel">Cancel</button>
    <button id="btn-apply">OK</button>
  </div>

  <script>
    function getParams() {
      const params = {};
      document.querySelectorAll('input[type="range"], input[type="checkbox"]').forEach(input => {
        params[input.id] = input.type === 'checkbox' ? input.checked : input.value;
      });
      return params;
    }

    function setUserDefaults(defaults) {
      Object.keys(defaults).forEach(id => {
        const input = document.getElementById(id);
        if (input) {
          if (input.type === 'checkbox') {
            input.checked = defaults[id];
          } else {
            input.value = defaults[id];
            const valueSpan = input.parentElement.querySelector('.slider-value');
            if (valueSpan) {
              const divisor = parseFloat(input.dataset.divisor) || 1;
              const displayValue = input.value / divisor;
              valueSpan.textContent = displayValue.toFixed(2);
            }
          }
        }
      });
      window.sketchup.preview(getParams());
    }

    document.querySelectorAll('input[type="range"]').forEach(slider => {
      slider.addEventListener('input', (e) => {
        const divisor = parseFloat(e.target.dataset.divisor) || 1;
        const displayValue = e.target.value / divisor;
        const valueSpan = e.target.parentElement.querySelector('.slider-value');
        if (valueSpan) {
          valueSpan.textContent = displayValue.toFixed(2);
        }
        window.sketchup.preview(getParams());
      });

      slider.addEventListener('change', (e) => {
        window.sketchup.update(getParams());
      });
    });

    document.querySelectorAll('input[type="checkbox"]').forEach(checkbox => {
      checkbox.addEventListener('change', () => {
        window.sketchup.update(getParams());
      });
    });

    document.getElementById('btn-apply').addEventListener('click', () => {
      window.sketchup.apply(getParams());
    });

    document.getElementById('btn-cancel').addEventListener('click', () => {
      window.sketchup.cancel();
    });

    document.getElementById('btn-reset').addEventListener('click', () => {
      window.sketchup.get_user_defaults();
    });

    // Handle Enter key press (same behavior as OK button)
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.keyCode === 13) {
        e.preventDefault();
        window.sketchup.apply(getParams());
      }
    });
  </script>
</body>
</html>
          HTML
        end

        # Build HTML for a single control.
        #
        # Dispatches to type-specific builder (slider or checkbox).
        #
        # @param ctrl [Hash] Control definition
        # @return [String] HTML fragment
        def build_control_html(ctrl)
          case ctrl[:type]
          when :slider
            build_slider_html(ctrl)
          when :checkbox
            build_checkbox_html(ctrl)
          else
            raise "Unknown control type: #{ctrl[:type]}"
          end
        end

        # Build HTML for slider control.
        #
        # Generates slider with label and live value display in a white box (.control-group).
        # Divisor is stored in data-divisor attribute for JavaScript conversion.
        #
        # @param ctrl [Hash] Slider definition
        #   - id: Control ID (string)
        #   - label: Display label (string)
        #   - min: Minimum value (integer)
        #   - max: Maximum value (integer)
        #   - default: Initial value (integer)
        #   - divisor: Conversion factor for display (e.g., 100 for percentage)
        #
        # @return [String] HTML fragment
        def build_slider_html(ctrl)
          id = ctrl[:id]
          label = ctrl[:label]
          min = ctrl[:min]
          max = ctrl[:max]
          default = ctrl[:default]
          divisor = ctrl[:divisor] || 1
          display_value = (default.to_f / divisor).round(2)

          <<-HTML
<div class="control-group">
  <label>#{label}</label>
  <div class="slider-container">
    <input type="range" id="#{id}" min="#{min}" max="#{max}" value="#{default}" data-divisor="#{divisor}">
    <span class="slider-value">#{display_value}</span>
  </div>
</div>
          HTML
        end

        # Build HTML for checkbox control.
        #
        # Generates checkbox with label in a white box (.control-group).
        #
        # @param ctrl [Hash] Checkbox definition
        #   - id: Control ID (string)
        #   - label: Display label (string)
        #   - default: Initial state (boolean)
        #
        # @return [String] HTML fragment
        def build_checkbox_html(ctrl)
          id = ctrl[:id]
          label = ctrl[:label]
          checked = ctrl[:default] ? 'checked' : ''

          <<-HTML
<div class="control-group">
  <div class="checkbox-container">
    <input type="checkbox" id="#{id}" #{checked}>
    <label for="#{id}">#{label}</label>
  </div>
</div>
          HTML
        end

        # Set up JavaScript callbacks (Ruby ↔ JavaScript communication).
        #
        # Registers callback handlers for:
        # - preview: Live preview during slider drag
        # - update: Final update on slider release
        # - apply: Apply/OK button
        # - cancel: Cancel button
        # - get_user_defaults: Reset button (requests defaults from Ruby)
        #
        # @return [void]
        def register_callbacks
          @dialog.add_action_callback('preview') do |action_context, params|
            on_preview(params)
          end

          @dialog.add_action_callback('update') do |action_context, params|
            on_update(params)
          end

          @dialog.add_action_callback('apply') do |action_context, params|
            on_apply(params)
          end

          @dialog.add_action_callback('cancel') do |action_context|
            on_cancel
          end

          @dialog.add_action_callback('get_user_defaults') do |action_context|
            defaults = get_user_defaults
            @dialog.execute_script("setUserDefaults(#{defaults.to_json});")
          end
        end

        # Save window position to preferences.
        #
        # Stores current dialog position (x, y) for next time dialog is opened.
        # Safe to call even if dialog position cannot be determined.
        #
        # @return [void]
        def save_window_position
          return unless @dialog

          begin
            x = @dialog.get_position[0]
            y = @dialog.get_position[1]
            ::Sketchup.write_default(@pref_key, 'window_x', x)
            ::Sketchup.write_default(@pref_key, 'window_y', y)
          rescue => e
            puts "[DialogBase] Could not save window position: #{e.message}" if ::Sketchup.debug_mode?
          end
        end
      end # class DialogBase
    end # module Shared
  end # module CurvyQuads
end # module MarcelloPanicciaTools
