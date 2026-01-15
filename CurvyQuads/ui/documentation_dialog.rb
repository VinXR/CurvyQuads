# frozen_string_literal: true

#==============================================================================
# CurvyQuads - Documentation Dialog (Placeholder)
#==============================================================================
# Purpose: Display help, tutorials, and known issues
#
# Current implementation: Simple placeholder
# Future: Will be expanded with full documentation content
#==============================================================================

module MarcelloPanicciaTools
  module CurvyQuads
    module UI
      module DocumentationDialog
        extend self

        PREF_KEY = 'CurvyQuads_DocumentationDialog'

        # Show documentation dialog.
        #
        # @return [void]
        #
        def show
          return if @dialog && @dialog.visible?

          @dialog = create_dialog
          @dialog.show
        end

        private

        # Create documentation dialog.
        #
        # @return [UI::HtmlDialog] The dialog
        #
        def create_dialog
          # Placeholder: modest size
          width = 500
          height = 400

          last_x = Sketchup.read_default(PREF_KEY, 'window_x', 300)
          last_y = Sketchup.read_default(PREF_KEY, 'window_y', 100)

          options = {
            dialog_title: 'CurvyQuads - Documentation',
            preferences_key: PREF_KEY,
            scrollable: true,
            resizable: true,
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

        # Build HTML for documentation dialog.
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
    <h1>CurvyQuads Suite</h1>
    <p class="version">Version 1.0.0 - Development Build</p>
    
    <h2>📋 Quick Reference</h2>
    
    <!-- Tool 1: Regularize -->
    <div class="tool-card">
      <h3>Regularize</h3>
      <p>Transform edge loops into perfect circles using best-fit circle algorithm.</p>
      <ul>
        <li><strong>Selection:</strong> Preselection (edges or faces)</li>
        <li><strong>Intensity:</strong> 0% = no change, 100% = perfect circle</li>
      </ul>
    </div>

    <!-- Tool 2: Spherify Geometry -->
    <div class="tool-card">
      <h3>Spherify Geometry</h3>
      <p>Spherical deformation for raw geometry inside groups/components.</p>
      <ul>
        <li><strong>Constraint:</strong> Must be used inside edit context (NOT world-level)</li>
        <li><strong>Amount:</strong> 0-100% spherical projection strength</li>
        <li><strong>Radius:</strong> 50-150% size multiplier</li>
      </ul>
    </div>

    <!-- Tool 3: Spherify Objects -->
    <div class="tool-card">
      <h3>Spherify Objects</h3>
      <p>Spherical deformation for Groups and Components.</p>
      <ul>
        <li><strong>Constraint:</strong> Flat structures only (no nested groups/components)</li>
        <li><strong>Components:</strong> All instances update simultaneously</li>
      </ul>
    </div>

    <!-- Tool 4: Set Flow -->
    <div class="tool-card">
      <h3>Set Flow</h3>
      <p>Conform edge loops to adjacent curvature using Bezier interpolation.</p>
      <ul>
        <li><strong>Selection:</strong> Dynamic (select after activation)</li>
        <li><strong>Intensity:</strong> 0-200% range (values > 100% exaggerate)</li>
      </ul>
    </div>

    <h2>⚙️ QuadFace Tools Convention</h2>
    <p>All tools use the QuadFace Tools (QFT) convention by Thomas Thomassen:</p>
    <ul>
      <li>Diagonal edges: soft + smooth + no cast shadows</li>
      <li>Automatic pre-triangulation for stability</li>
      <li>UV coordinates preserved (when enabled)</li>
    </ul>

    <h2>📚 Full Documentation</h2>
    <p><em>Detailed documentation will be added in future releases.</em></p>
    <p>For now, experiment with tools and check Ruby Console for errors.</p>

  </div>
  
  <div class="footer">
    <button class="primary" onclick="closeDialog()">Close</button>
  </div>

  <script>
    function closeDialog() {
      sketchup.close(window.screenX, window.screenY);
    }
  </script>
</body>
</html>
          HTML
        end

        # Build CSS for dialog.
        #
        # @return [String] CSS stylesheet
        #
        def build_css
          <<-CSS
body {
  font-family: 'Segoe UI', sans-serif;
  background: #f9f9f9;
  padding: 16px;
  font-size: 12px;
  margin: 0;
  display: flex;
  flex-direction: column;
  height: 100vh;
  box-sizing: border-box;
}

.content {
  flex: 1;
  overflow-y: auto;
  padding-right: 8px;
}

h1 {
  font-size: 20px;
  margin: 0 0 4px 0;
  color: #0078d7;
}

.version {
  font-size: 11px;
  color: #666;
  margin: 0 0 20px 0;
}

h2 {
  font-size: 14px;
  margin: 20px 0 10px 0;
  color: #333;
  border-bottom: 2px solid #0078d7;
  padding-bottom: 4px;
}

.tool-card {
  background: white;
  border: 1px solid #ddd;
  border-radius: 4px;
  padding: 12px;
  margin-bottom: 12px;
  box-shadow: 0 1px 3px rgba(0,0,0,0.1);
}

.tool-card h3 {
  font-size: 13px;
  margin: 0 0 6px 0;
  color: #0078d7;
}

.tool-card p {
  margin: 0 0 8px 0;
  line-height: 1.4;
}

.tool-card ul {
  margin: 0;
  padding-left: 20px;
}

.tool-card li {
  margin-bottom: 4px;
  line-height: 1.4;
}

.footer {
  margin-top: 16px;
  padding-top: 12px;
  border-top: 1px solid #ddd;
  display: flex;
  justify-content: flex-end;
}

button {
  padding: 8px 24px;
  cursor: pointer;
  border: 1px solid #ccc;
  background: #e0e0e0;
  border-radius: 3px;
  font-size: 12px;
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

        # Register JavaScript callbacks.
        #
        # @param dialog [UI::HtmlDialog] The dialog
        # @return [void]
        #
        def register_callbacks(dialog)
          dialog.add_action_callback('close') do |_, x, y|
            Sketchup.write_default(PREF_KEY, 'window_x', x.to_i) if x
            Sketchup.write_default(PREF_KEY, 'window_y', y.to_i) if y
            dialog.close
          end
        end

      end # module DocumentationDialog
    end # module UI
  end # module CurvyQuads
end # module MarcelloPanicciaTools
