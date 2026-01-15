# frozen_string_literal: true

#==============================================================================
# CurvyQuads Plugin - Selection Tracker Module
# Copyright (c) 2025 Marcello Paniccia
#==============================================================================
# Dynamic selection tracking with timer and observer
#
# Provides real-time monitoring of selection changes during tool operation:
# - Timer-based polling (default 0.20s) detects selection changes
# - ModelObserver detects context changes (user enters/exits groups)
# - Callback system notifies tool when refresh needed
#
# Used by:
# - Spherify Geometry (live preview with dynamic selection)
# - Spherify Objects (live preview with dynamic selection)
# - Set Flow (live preview with dynamic selection)
#
# NOT used by:
# - Regularize (static selection, uses SketchUp Tool API)
#
# Usage:
#   def activate
#     @tracker = SelectionTracker.start_tracking(@model) do
#       refresh_geometry_session  # Your callback
#     end
#   end
#
#   def refresh_geometry_session
#     @tracker.processing = true
#     # ... do work ...
#     @tracker.processing = false
#   end
#
#   def cleanup
#     @tracker.stop if @tracker
#   end
#==============================================================================

module MarcelloPanicciaTools
module CurvyQuads
module Shared
module SelectionTracker
  extend self

  # Start tracking selection changes.
  #
  # Creates timer (polls every interval) and observer (monitors context changes).
  # When selection or context changes, calls callback block.
  #
  # @param model [Sketchup::Model] The model
  # @param interval [Float] Polling interval in seconds (default 0.20)
  # @param on_change [Proc] Callback when selection changes (passed as block)
  # @return [SelectionSession] Session object
  #
  # @example Basic usage
  #   @tracker = SelectionTracker.start_tracking(@model) do
  #     puts "Selection changed!"
  #     refresh_geometry_session
  #   end
  #
  # @example Custom interval
  #   @tracker = SelectionTracker.start_tracking(@model, interval: 0.10) do
  #     refresh_geometry_session
  #   end
  #
  def start_tracking(model, interval: 0.20, &on_change)
    SelectionSession.new(model, interval, on_change)
  end

  # Selection tracking session.
  #
  # Manages timer and observer lifecycle.
  # Call stop when done to cleanup resources.
  #
  class SelectionSession
    # Initialize tracking session.
    #
    # @param model [Sketchup::Model] The model
    # @param interval [Float] Polling interval in seconds
    # @param on_change [Proc] Callback for selection changes
    #
    def initialize(model, interval, on_change)
      @model = model
      @selection = model.selection
      @interval = interval
      @on_change = on_change
      @last_sel_ids = []
      @timer_id = nil
      @observer = nil
      @committed = false
      @is_processing = false

      start_monitoring
    end

    # Start timer and observer.
    #
    # Captures initial selection state and begins polling.
    #
    # @return [void]
    #
    def start_monitoring
      @last_sel_ids = @selection.to_a.map(&:entityID).sort
      @observer = ContextChangeObserver.new(self)
      @model.add_observer(@observer)
      @timer_id = ::UI.start_timer(@interval, true) { check_selection_change }  # FIX: ::UI
      puts "[SelectionTracker] Started monitoring (interval: #{@interval}s)"
    end

    # Check if selection changed (called by timer).
    #
    # Compares current selection with last known state.
    # If changed, restarts timer and triggers callback.
    #
    # @return [void]
    #
    def check_selection_change
      return if @committed || @is_processing

      current_sel = @selection.to_a
      current_ids = current_sel.map(&:entityID).sort

      if current_ids != @last_sel_ids
        # Stop timer temporarily during callback
        ::UI.stop_timer(@timer_id) if @timer_id  # FIX: ::UI

        # Trigger callback
        @on_change.call if @on_change

        # Update tracking state
        @last_sel_ids = current_ids

        # Restart timer
        @timer_id = ::UI.start_timer(@interval, true) { check_selection_change }  # FIX: ::UI
      end
    end

    # Handle context change (user entered/exited group).
    #
    # Context changes typically require tool to close/reset.
    # Calls stop to cleanup resources.
    #
    # @return [void]
    #
    def on_context_changed
      puts "[SelectionTracker] Context changed - stopping tracking"
      stop
    end

    # Stop tracking and cleanup.
    #
    # Stops timer, removes observer, releases resources.
    # Safe to call multiple times (idempotent).
    #
    # @return [void]
    #
    def stop
      @committed = true
      ::UI.stop_timer(@timer_id) if @timer_id  # FIX: ::UI
      @timer_id = nil
      @model.remove_observer(@observer) if @observer
      @observer = nil
      puts "[SelectionTracker] Stopped monitoring"
    end

    # Mark processing state (prevents recursive updates).
    #
    # Set to true before processing callback, false after.
    # Prevents timer from triggering callback while already processing.
    #
    # @param state [Boolean] Processing state
    # @return [void]
    #
    # @example Usage in callback
    #   def refresh_geometry_session
    #     @tracker.processing = true
    #     # ... do work ...
    #     @tracker.processing = false
    #   end
    #
    def processing=(state)
      @is_processing = state
    end
  end

  # Observer for context changes.
  #
  # Detects when user enters/exits groups (onActivePathChanged).
  # Notifies session to stop tracking.
  #
  class ContextChangeObserver < Sketchup::ModelObserver
    # Initialize observer.
    #
    # @param session [SelectionSession] Parent session
    #
    def initialize(session)
      @session = session
    end

    # Handle active path change (context change).
    #
    # Called when user enters/exits groups or components.
    # Delegates to session's on_context_changed.
    #
    # @param model [Sketchup::Model] The model
    # @return [void]
    #
    def onActivePathChanged(model)
      @session.on_context_changed
    end
  end

end # module SelectionTracker
end # module Shared
end # module CurvyQuads
end # module MarcelloPanicciaTools
