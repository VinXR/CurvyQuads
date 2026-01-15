# frozen_string_literal: true

#==============================================================================
# CurvyQuads Suite - Extension Registration
#==============================================================================
# Purpose:      Registers the extension with SketchUp and loads main suite
# 
# Code Quality: Production-ready for peer review by senior developers
#               (ThomThom, Fredo6 standards).
#
# DEVELOPMENT vs PRODUCTION:
# --------------------------
# This file works in BOTH modes automatically:
#
# DEVELOPMENT MODE:
#   - CurvyQuads_DevLoader.rb sets ENV['CURVYQUADS_DEV_PATH']
#   - loader.rb detects ENV and loads from X:/CurvyQuads_Dev/
#   - Hot-reload available via Plugins > Developer menu
#
# PRODUCTION MODE (for .rbz packaging):
#   - Delete CurvyQuads_DevLoader.rb
#   - ENV['CURVYQUADS_DEV_PATH'] will be nil
#   - loader.rb loads normally from Plugins/CurvyQuads/
#   - No code changes needed in this file!
#
# The ENV variable is set by DevLoader BEFORE this file runs,
# so no modifications are needed here for dev/production switch.
#==============================================================================

require 'sketchup.rb'
require 'extensions.rb'

module MarcelloPanicciaTools
  module CurvyQuads

    # Extension metadata constants
    EXTENSION_NAME    = 'CurvyQuads Suite'
    EXTENSION_VERSION = '1.0.0'
    EXTENSION_AUTHOR  = 'Marcello Paniccia'

    unless file_loaded?(__FILE__)

      # Create SketchupExtension object
      # Loader path is relative to Plugins folder
      # (loader.rb will auto-detect dev vs production mode via ENV)
      extension = SketchupExtension.new(EXTENSION_NAME, 'CurvyQuads/loader')

      # Extension metadata
      extension.description = 
        'Professional quad mesh manipulation suite with Regularize, ' \
        'Spherify (geometry/objects), and Set Flow tools. ' \
        'Organic modeling workflows ported from 3ds Max.'
      
      extension.version  = EXTENSION_VERSION
      extension.creator  = EXTENSION_AUTHOR
      extension.copyright = "#{Time.now.year} #{EXTENSION_AUTHOR}"

      # Register extension with SketchUp
      # Second parameter 'true' = load on startup
      Sketchup.register_extension(extension, true)

      file_loaded(__FILE__)
    end

  end # module CurvyQuads
end # module MarcelloPanicciaTools

#==============================================================================
# PRODUCTION PACKAGING CHECKLIST:
# ================================
# 1. DELETE: Plugins/CurvyQuads_DevLoader.rb
# 2. DELETE: X:/CurvyQuads_Dev/ folder (entire dev environment)
# 3. KEEP:   This file (CurvyQuads.rb) - NO changes needed
# 4. KEEP:   Plugins/CurvyQuads/ folder with all .rb files
# 5. Create .rbz: Zip CurvyQuads.rb + CurvyQuads/ folder, rename to .rbz
#
# The system auto-detects production mode when DevLoader is absent.
#==============================================================================
