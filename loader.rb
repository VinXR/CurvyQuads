# frozen_string_literal: true

#==============================================================================
# CurvyQuads Suite - Main Loader
# Copyright (c) 2025 Marcello Paniccia
#==============================================================================
# This file orchestrates the loading of all suite components in the correct order:
# 1. Shared modules (geometry, UV, topology, settings, tool manager, selection tracking)
# 2. UI foundation (base dialog classes)
# 3. Tool implementations (Regularize, Spherify, SetFlow)
# 4. UI components (toolbar, settings dialog, documentation)
#
# @author Marcello Paniccia
# @version 2.0.0
#==============================================================================

module MarcelloPanicciaTools
module CurvyQuads

  # Determine plugin root path
  # In dev mode: ENV['CURVYQUADS_DEV_PATH'] is set by AAA_CurvyQuads_DevLoader.rb
  # In production: Uses standard Plugins/CurvyQuads/ directory
  if ENV['CURVYQUADS_DEV_PATH']
    PLUGIN_ROOT = ENV['CURVYQUADS_DEV_PATH']
    puts "[CurvyQuads] DEV MODE - Loading from: #{PLUGIN_ROOT}"
  else
    PLUGIN_ROOT = File.dirname(__FILE__)
    puts "[CurvyQuads] PRODUCTION MODE - Loading from: #{PLUGIN_ROOT}"
  end

  # Preferences namespace for SketchUp registry
  PREF_NAMESPACE = 'MarcelloPaniccia_CurvyQuads'

  # Track if UI (toolbar/menu) has been initialized
  @ui_initialized = false

  # Load shared utility modules
  # These provide common functionality used by all tools
  #
  # ORDER MATTERS:
  # - geometry_utils: Geometry operations (includes triangulation)
  # - uv_helper: UV preservation utilities
  # - topology_analyzer: QFT detection
  # - settings_manager: Plugin settings persistence
  # - tool_manager: Tool conflict prevention (mutex system)
  # - selection_tracker: Dynamic selection monitoring (timer + observer)
  # - ui_manager: LAST (uses settings_manager)
  #
  # @return [void]
  #
  def self.load_shared_modules
    puts "[CurvyQuads] Loading shared modules..."

    [
      'shared/geometry_utils.rb',       # Geometry ops + triangulation (Session Spherify)
      'shared/uv_helper.rb',             # UV preservation
      'shared/topology_analyzer.rb',     # QFT detection
      'shared/settings_manager.rb',      # Settings persistence
      'shared/tool_manager.rb',          # ← NUOVO! Mutex tools (Q&A #6)
      'shared/selection_tracker.rb',     # ← NUOVO! Selezione dinamica
      'shared/catmullrom_spline.rb',     # Catmull-Rom spline mathematics
      'shared/catmullrom_topology.rb',   # Catmull-Rom mesh navigation
      'shared/catmullrom_visualizer.rb'  # Catmull-Rom diagnostic visualization
    ].each do |path|
      full_path = File.join(PLUGIN_ROOT, path)
      puts "  → #{path}"
      load full_path
    end
  end

  # Load UI foundation (base dialog classes)
  #
  # Loaded AFTER shared modules (uses settings_manager).
  #
  # @return [void]
  #
  def self.load_ui_foundation
    puts "[CurvyQuads] Loading UI foundation..."
    load File.join(PLUGIN_ROOT, 'shared/ui_manager.rb')
  end

  # Load tool implementations
  #
  # @return [void]
  #
  def self.load_tools
    puts "[CurvyQuads] Loading tools..."

    [
      'tools/regularize_tool.rb',
      'tools/spherify_geometry_tool.rb',
      'tools/spherify_objects_tool.rb',
      'tools/set_flow_tool.rb',
      'tools/catmullrom_aligner_tool.rb'
    ].each do |path|
      full_path = File.join(PLUGIN_ROOT, path)
      puts "  → #{path}"
      load full_path
    end
  end

  # Load UI components (toolbar, dialogs)
  #
  # @return [void]
  #
  def self.load_ui_components
    puts "[CurvyQuads] Loading UI components..."

    [
      'ui/toolbar_manager.rb',
      'ui/settings_dialog.rb',
      'ui/documentation_dialog.rb'
    ].each do |path|
      full_path = File.join(PLUGIN_ROOT, path)
      puts "  → #{path}"
      load full_path
    end
  end

  # Initialize UI (toolbar and menu) - ONLY ONCE
  #
  # @return [void]
  #
  def self.initialize_ui
    return if @ui_initialized

    puts "[CurvyQuads] Initializing UI (toolbar and menu)..."
    UI::ToolbarManager.mp3d_cq_create_toolbar
    mp3d_cq_register_menus
    @ui_initialized = true
  end

  # Main loading sequence
  #
  # @return [void]
  #
  def self.load_suite
    begin
      load_shared_modules
      load_ui_foundation
      load_tools
      load_ui_components

      # Initialize UI only on first load
      initialize_ui

      puts "[CurvyQuads] ✓ Suite loaded successfully"
    rescue => e
      puts "[CurvyQuads] ✗ ERROR during loading:"
      puts "  #{e.class}: #{e.message}"
      puts e.backtrace.join("\n  ")
      ::UI.messagebox(
        "CurvyQuads failed to load:\n\n#{e.message}\n\nCheck Ruby Console for details.",
        MB_OK
      )
    end
  end

  # Register menu items
  # Creates: Extensions > Marcello Paniccia Tools > CurvyQuads > [6 items]
  #
  # @return [void]
  #
  def self.mp3d_cq_register_menus
    # Get or create parent menu
    extensions_menu = ::UI.menu('Extensions')
    mp_menu = extensions_menu.add_submenu('Marcello Paniccia Tools')
    cq_menu = mp_menu.add_submenu('CurvyQuads')

    # Add tool items (same order as toolbar)
    cq_menu.add_item('Regularize') { Tools::RegularizeTool.activate }
    cq_menu.add_item('Spherify Geometry') { Tools::SpherifyGeometryTool.activate }
    cq_menu.add_item('Spherify Objects') { Tools::SpherifyObjectsTool.activate }
    cq_menu.add_item('Set Flow') { Tools::SetFlowTool.activate }

    # Add Catmull-Rom Aligner submenu
    catmullrom_menu = cq_menu.add_submenu('Catmull-Rom Aligner')
    catmullrom_menu.add_item('Analyze Selection') { CatmullRomAlignerTool.analyze_selection }
    catmullrom_menu.add_item('Clear Debug Geometry') { CatmullRomAlignerTool.clear_debug_geometry }

    # Add separator
    cq_menu.add_separator

    # Add utility items
    cq_menu.add_item('Settings') { UI::SettingsDialog.show }
    cq_menu.add_item('Documentation') { UI::DocumentationDialog.show }
  end

  # Hot-reload command for development
  # Reloads ONLY Ruby modules (not UI elements like toolbar/menu)
  # Accessible via Plugins > CurvyQuads Developer > Reload
  #
  # @return [void]
  #
  def self.reload_suite
    puts "\n" + ("=" * 60)
    puts "[CurvyQuads] RELOADING SUITE..."
    puts ("=" * 60)

    # Reload modules only (NOT UI creation)
    load_shared_modules
    load_ui_foundation
    load_tools
    load_ui_components

    puts "[CurvyQuads] ✓ Suite reloaded successfully"
    puts "Note: Toolbar/menu changes require SketchUp restart"
    puts ("=" * 60)
  end

  # Execute loading on require
  load_suite

end # module CurvyQuads
end # module MarcelloPanicciaTools
