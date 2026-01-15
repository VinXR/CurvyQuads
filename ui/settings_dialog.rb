# frozen_string_literal: true

#==============================================================================
# CurvyQuads - Settings Dialog
#==============================================================================
# Purpose: Configure default parameters for all tools + toolbar visibility
#
# This dialog allows users to set:
# - Default parameter values for each tool (intensity, amount, radius_mult)
# - Preserve UV checkbox default state per-tool
# - Toolbar button visibility
#
# Reset button restores factory defaults.
#
# Dialog specs:
# - Width: 266px (fixed)
# - Height: 650px (fixed with scroll - prevents excessive height)
#==============================================================================

module MarcelloPanicciaTools
  module CurvyQuads
    module UI
      module SettingsDialog
        extend self

        PREF_KEY = 'CurvyQuads_SettingsDialog'

        # Show settings dialog.
        #
        # @return [void]
        #
        def show
          return if @dialog && @dialog.visible?

          @dialog = create_dialog
          @dialog.show
        end

        private

        # Create settings dialog.
        #
        # @return [UI::HtmlDialog] The dialog
        #
        def create_dialog
          width = 266
          height = 650 # Fixed height with scroll (content is ~800px)

          # Restore window position
          last_x = Sketchup.read_default(PREF_KEY, 'window_x', 400)
          last_y = Sketchup.read_default(PREF_KEY, 'window_y', 100)

          options = {
            dialog_title: 'CurvyQuads - Settings',
            preferences_key: PREF_KEY,
            scrollable: true,
            resizable: false,
            width: width,
            height: height,
            left: last_x,
            top: last_y,
            style: ::UI::HtmlDialog::STYLE_DIALOG
          }

          dialog = ::UI::HtmlDialog.new(options)
          dialog.set_html(build_html)
          register_callbacks(dialog)
          dialog.set_on_closed { @dialog = nil }
          dialog
        end

        # Build HTML for settings dialog.
        #
        # @return [String] Complete HTML document
        #
        def build_html
          <<-HTML
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>#{build_css}</style>
</head>
<body>
  <div class="content">
    <h2>Tool Default Parameters</h2>
    
    <!-- Regularize -->
    <div class="tool-section">
      <h3>Regularize</h3>
      <div class="control-group">
        <label>
          Intensity
          <span class="value-display" id="reg_intensity_val">#{get_saved('regularize', 'intensity', 1.0)}</span>
        </label>
        <input type="range" id="reg_intensity" min="0" max="100" value="#{(get_saved('regularize', 'intensity', 1.0) * 100).to_i}"
               oninput="updateValue('reg_intensity')">
      </div>
      <div class="control-group">
        <label class="checkbox-label">
          <input type="checkbox" id="reg_preserve_uv" #{get_saved('regularize', 'preserve_uv', false) ? 'checked' : ''}>
          Preserve UV
        </label>
      </div>
    </div>

    <!-- Set Flow -->
    <div class="tool-section">
      <h3>Set Flow</h3>
      <div class="control-group">
        <label>
          Intensity
          <span class="value-display" id="flow_intensity_val">#{get_saved('set_flow', 'intensity', 1.0)}</span>
        </label>
        <input type="range" id="flow_intensity" min="0" max="200" value="#{(get_saved('set_flow', 'intensity', 1.0) * 100).to_i}"
               oninput="updateValue('flow_intensity')">
      </div>
      <div class="control-group">
        <label class="checkbox-label">
          <input type="checkbox" id="flow_preserve_uv" #{get_saved('set_flow', 'preserve_uv', false) ? 'checked' : ''}>
          Preserve UV
        </label>
      </div>
    </div>

    <!-- Spherify Geometry -->
    <div class="tool-section">
      <h3>Spherify Geometry</h3>
      <div class="control-group">
        <label>
          Amount
          <span class="value-display" id="sgeo_amount_val">#{get_saved('spherify_geometry', 'amount', 1.0)}</span>
        </label>
        <input type="range" id="sgeo_amount" min="0" max="100" value="#{(get_saved('spherify_geometry', 'amount', 1.0) * 100).to_i}"
               oninput="updateValue('sgeo_amount')">
      </div>
      <div class="control-group">
        <label>
          Radius Multiplier
          <span class="value-display" id="sgeo_radius_val">#{get_saved('spherify_geometry', 'radius_mult', 1.0)}</span>
        </label>
        <input type="range" id="sgeo_radius" min="50" max="150" value="#{(get_saved('spherify_geometry', 'radius_mult', 1.0) * 100).to_i}"
               oninput="updateValue('sgeo_radius')">
      </div>
      <div class="control-group">
        <label class="checkbox-label">
          <input type="checkbox" id="sgeo_preserve_uv" #{get_saved('spherify_geometry', 'preserve_uv', false) ? 'checked' : ''}>
          Preserve UV
        </label>
      </div>
    </div>

    <!-- Spherify Objects -->
    <div class="tool-section">
      <h3>Spherify Objects</h3>
      <div class="control-group">
        <label>
          Amount
          <span class="value-display" id="sobj_amount_val">#{get_saved('spherify_objects', 'amount', 1.0)}</span>
        </label>
        <input type="range" id="sobj_amount" min="0" max="100" value="#{(get_saved('spherify_objects', 'amount', 1.0) * 100).to_i}"
               oninput="updateValue('sobj_amount')">
      </div>
      <div class="control-group">
        <label>
          Radius Multiplier
          <span class="value-display" id="sobj_radius_val">#{get_saved('spherify_objects', 'radius_mult', 1.0)}</span>
        </label>
        <input type="range" id="sobj_radius" min="50" max="150" value="#{(get_saved('spherify_objects', 'radius_mult', 1.0) * 100).to_i}"
               oninput="updateValue('sobj_radius')">
      </div>
      <div class="control-group">
        <label class="checkbox-label">
          <input type="checkbox" id="sobj_preserve_uv" #{get_saved('spherify_objects', 'preserve_uv', false) ? 'checked' : ''}>
          Preserve UV
        </label>
      </div>
    </div>

    <!-- Toolbar Visibility -->
    <h2>Toolbar Visibility</h2>
    <div class="tool-section">
      <div class="control-group">
        <label class="checkbox-label">
          <input type="checkbox" id="vis_regularize" #{get_button_visibility('regularize') ? 'checked' : ''}>
          Regularize
        </label>
      </div>
      <div class="control-group">
        <label class="checkbox-label">
          <input type="checkbox" id="vis_spherify_geometry" #{get_button_visibility('spherify_geometry') ? 'checked' : ''}>
          Spherify Geometry
        </label>
      </div>
      <div class="control-group">
        <label class="checkbox-label">
          <input type="checkbox" id="vis_spherify_objects" #{get_button_visibility('spherify_objects') ? 'checked' : ''}>
          Spherify Objects
        </label>
      </div>
      <div class="control-group">
        <label class="checkbox-label">
          <input type="checkbox" id="vis_set_flow" #{get_button_visibility('set_flow') ? 'checked' : ''}>
          Set Flow
        </label>
      </div>
      <div class="control-group">
        <label class="checkbox-label">
          <input type="checkbox" id="vis_settings" #{get_button_visibility('settings') ? 'checked' : ''}>
          Settings
        </label>
      </div>
      <div class="control-group">
        <label class="checkbox-label">
          <input type="checkbox" id="vis_documentation" #{get_button_visibility('documentation') ? 'checked' : ''}>
          Documentation
        </label>
      </div>
      <p class="note">Changes to toolbar visibility require SketchUp restart.</p>
    </div>

  </div>
  
  <div class="footer">
    <button onclick="resetDefaults()">Reset</button>
    <button onclick="cancel()">Cancel</button>
    <button class="primary" onclick="apply()">OK</button>
  </div>

  <script>#{build_javascript}</script>
</body>
</html>
          HTML
        end

        # Get saved parameter or default.
        #
        # @param tool_name [String] Tool identifier
        # @param param_name [String] Parameter name
        # @param default [Object] Default value
        # @return [Object] Saved or default value
        #
        def get_saved(tool_name, param_name, default)
          Shared::SettingsManager.mp3d_cq_get_parameter(tool_name, param_name) || default
        end

        # Get button visibility state.
        #
        # @param button_id [String] Button identifier
        # @return [Boolean] Visibility state
        #
        def get_button_visibility(button_id)
          Shared::SettingsManager.mp3d_cq_button_visible?(button_id)
        end

        # Build CSS for dialog.
        #
        # @return [String] CSS stylesheet
        #
        def build_css
          <<-CSS
body {
  font-family: 'Segoe UI', sans-serif;
  background: #f0f0f0;
  padding: 8px;
  font-size: 11px;
  margin: 0;
  display: flex;
  flex-direction: column;
  height: 100vh;
  box-sizing: border-box;
}

.content {
  flex: 1;
  overflow-y: auto;
  padding-right: 4px;
}

h2 {
  font-size: 13px;
  margin: 0 0 10px 0;
  color: #333;
  font-weight: 600;
}

.tool-section {
  background: #fff;
  border: 1px solid #ccc;
  border-radius: 3px;
  padding: 10px;
  margin-bottom: 8px;
  box-shadow: 0 1px 2px rgba(0,0,0,0.05);
}

.tool-section h3 {
  font-size: 12px;
  font-weight: 600;
  margin: 0 0 8px 0;
  color: #0078d7;
  border-bottom: 1px solid #e0e0e0;
  padding-bottom: 4px;
}

.control-group {
  margin-bottom: 8px;
}

.control-group:last-child {
  margin-bottom: 0;
}

label {
  display: flex;
  justify-content: space-between;
  font-weight: 600;
  margin-bottom: 3px;
  color: #333;
  font-size: 11px;
}

.value-display {
  font-weight: normal;
  color: #666;
}

input[type=range] {
  width: 100%;
  margin: 0;
  cursor: pointer;
  height: 18px;
}

.checkbox-label {
  font-weight: normal;
  display: flex;
  align-items: center;
  cursor: pointer;
  margin: 0;
}

.checkbox-label input {
  margin-right: 6px;
}

.note {
  font-size: 10px;
  color: #666;
  margin: 8px 0 0 0;
  font-style: italic;
}

.footer {
  margin-top: 8px;
  padding-top: 8px;
  display: flex;
  gap: 4px;
  border-top: 1px solid #ccc;
}

button {
  flex: 1;
  padding: 6px 0;
  cursor: pointer;
  border: 1px solid #ccc;
  background: #e0e0e0;
  border-radius: 2px;
  font-size: 11px;
  font-weight: 600;
  outline: none;
}

button:hover { background: #d0d0d0; }
button:active { background: #c0c0c0; }

button.primary {
  background: #0078d7;
  color: white;
  border-color: #005a9e;
}

button.primary:hover { background: #006cc1; }
          CSS
        end

        # Build JavaScript for dialog.
        #
        # @return [String] JavaScript code
        #
        def build_javascript
          <<-JS
function updateValue(id) {
  var slider = document.getElementById(id);
  var display = document.getElementById(id + '_val');
  var value = parseFloat(slider.value);
  
  // Convert slider value to actual parameter value
  if (id.includes('radius')) {
    display.innerText = (value / 100.0).toFixed(2);
  } else if (id.includes('intensity') && id.includes('flow')) {
    display.innerText = (value / 100.0).toFixed(2);
  } else {
    display.innerText = (value / 100.0).toFixed(2);
  }
}

function getValues() {
  return {
    tool_params: {
      regularize: {
        intensity: parseFloat(document.getElementById('reg_intensity').value) / 100.0,
        preserve_uv: document.getElementById('reg_preserve_uv').checked
      },
      set_flow: {
        intensity: parseFloat(document.getElementById('flow_intensity').value) / 100.0,
        preserve_uv: document.getElementById('flow_preserve_uv').checked
      },
      spherify_geometry: {
        amount: parseFloat(document.getElementById('sgeo_amount').value) / 100.0,
        radius_mult: parseFloat(document.getElementById('sgeo_radius').value) / 100.0,
        preserve_uv: document.getElementById('sgeo_preserve_uv').checked
      },
      spherify_objects: {
        amount: parseFloat(document.getElementById('sobj_amount').value) / 100.0,
        radius_mult: parseFloat(document.getElementById('sobj_radius').value) / 100.0,
        preserve_uv: document.getElementById('sobj_preserve_uv').checked
      }
    },
    toolbar_visibility: {
      regularize: document.getElementById('vis_regularize').checked,
      spherify_geometry: document.getElementById('vis_spherify_geometry').checked,
      spherify_objects: document.getElementById('vis_spherify_objects').checked,
      set_flow: document.getElementById('vis_set_flow').checked,
      settings: document.getElementById('vis_settings').checked,
      documentation: document.getElementById('vis_documentation').checked
    }
  };
}

function resetDefaults() {
  // Factory defaults for tool parameters
  document.getElementById('reg_intensity').value = 100;
  document.getElementById('reg_preserve_uv').checked = false;
  updateValue('reg_intensity');
  
  document.getElementById('flow_intensity').value = 100;
  document.getElementById('flow_preserve_uv').checked = false;
  updateValue('flow_intensity');
  
  document.getElementById('sgeo_amount').value = 100;
  document.getElementById('sgeo_radius').value = 100;
  document.getElementById('sgeo_preserve_uv').checked = false;
  updateValue('sgeo_amount');
  updateValue('sgeo_radius');
  
  document.getElementById('sobj_amount').value = 100;
  document.getElementById('sobj_radius').value = 100;
  document.getElementById('sobj_preserve_uv').checked = false;
  updateValue('sobj_amount');
  updateValue('sobj_radius');
  
  // Factory defaults for toolbar visibility (all visible)
  document.getElementById('vis_regularize').checked = true;
  document.getElementById('vis_spherify_geometry').checked = true;
  document.getElementById('vis_spherify_objects').checked = true;
  document.getElementById('vis_set_flow').checked = true;
  document.getElementById('vis_settings').checked = true;
  document.getElementById('vis_documentation').checked = true;
}

function apply() {
  sketchup.apply(JSON.stringify(getValues()), window.screenX, window.screenY);
}

function cancel() {
  sketchup.cancel(window.screenX, window.screenY);
}
          JS
        end

        # Register JavaScript callbacks.
        #
        # @param dialog [UI::HtmlDialog] The dialog
        # @return [void]
        #
        def register_callbacks(dialog)
          # Apply callback
          dialog.add_action_callback('apply') do |_, params_json, x, y|
            params = JSON.parse(params_json)
            save_window_position(x.to_i, y.to_i)
            save_all_parameters(params)
            ::UI.messagebox("Settings saved!\nRestart SketchUp for toolbar changes.", MB_OK)
            dialog.close
          end

          # Cancel callback
          dialog.add_action_callback('cancel') do |_, x, y|
            save_window_position(x.to_i, y.to_i)
            dialog.close
          end
        end

        # Save window position.
        #
        # @param x [Integer] X coordinate
        # @param y [Integer] Y coordinate
        # @return [void]
        #
        def save_window_position(x, y)
          Sketchup.write_default(PREF_KEY, 'window_x', x)
          Sketchup.write_default(PREF_KEY, 'window_y', y)
        end

        # Save all parameters.
        #
        # @param params [Hash] All settings
        # @return [void]
        #
        def save_all_parameters(params)
          # Save tool parameters
          params['tool_params'].each do |tool_name, tool_params|
            tool_params.each do |param_name, value|
              Shared::SettingsManager.mp3d_cq_set_default(tool_name.to_s, param_name.to_s, value)
            end
          end
          
          # Save toolbar visibility
          params['toolbar_visibility'].each do |button_id, visible|
            Shared::SettingsManager.mp3d_cq_set_button_visibility(button_id.to_s, visible)
          end
        end

      end # module SettingsDialog
    end # module UI
  end # module CurvyQuads
end # module MarcelloPanicciaTools
