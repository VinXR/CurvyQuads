# frozen_string_literal: true

#==============================================================================
# CurvyQuads Plugin - Tool Manager Module
# Copyright (c) 2025 Marcello Paniccia
#==============================================================================
# Tool conflict management (mutex system with automatic closure)
#
# Prevents multiple tools from operating simultaneously by automatically
# closing the active tool when a new one is activated.
#
# Behavior:
# - When tool A is active and tool B wants to activate:
#   → Tool A is automatically closed (Cancel operation)
#   → Tool B activates
# - No messagebox, smooth transition between tools
#
# Pattern:
# - Regularize: SketchUp Tool (static selection)
# - Spherify/SetFlow: Dialog with dynamic selection tracking
#
# Usage:
#   def activate
#     unless ToolManager.activate_tool(TOOL_NAME, self)
#       return  # Cleanup failed, abort activation
#     end
#     # ... rest of activation logic ...
#   end
#
#   def cleanup
#     ToolManager.deactivate_tool(TOOL_NAME)
#     # ... rest of cleanup logic ...
#   end
#==============================================================================

module MarcelloPanicciaTools
module CurvyQuads
module Shared
module ToolManager
  extend self

  @active_tool = nil
  @active_tool_instance = nil

  # Register tool activation with automatic closure of previous tool.
  #
  # If another tool is currently active, it will be automatically closed
  # (Cancel operation) before activating the new tool.
  #
  # @param tool_name [String] Tool identifier (e.g. "Spherify Geometry")
  # @param tool_instance [Object] Tool instance (for cleanup callback)
  # @return [Boolean] true if successfully activated, false if cleanup failed
  #
  # @example Activate tool
  #   unless ToolManager.activate_tool(TOOL_NAME, self)
  #     return  # Cleanup failed, abort
  #   end
  #
  def activate_tool(tool_name, tool_instance = nil)
    # If another tool is active, close it automatically
    if @active_tool && @active_tool != tool_name
      puts "[ToolManager] Closing active tool: #{@active_tool}"

      # Try to close the active tool gracefully
      if @active_tool_instance && @active_tool_instance.respond_to?(:on_cancel)
        begin
          @active_tool_instance.on_cancel
        rescue => e
          puts "[ToolManager] Error closing #{@active_tool}: #{e.message}"
          # Force close on error
          @active_tool = nil
          @active_tool_instance = nil
        end
      else
        # No cleanup method available, just release mutex
        @active_tool = nil
        @active_tool_instance = nil
      end
    end

    # Register new tool as active
    @active_tool = tool_name
    @active_tool_instance = tool_instance
    puts "[ToolManager] Activated: #{tool_name}"
    true
  end

  # Deactivate current tool.
  #
  # Releases mutex, allows other tools to activate.
  # Call this in cleanup/on_cancel/on_apply.
  #
  # @param tool_name [String] Tool identifier
  # @return [void]
  #
  # @example Cleanup
  #   ToolManager.deactivate_tool(TOOL_NAME)
  #
  def deactivate_tool(tool_name)
    if @active_tool == tool_name
      @active_tool = nil
      @active_tool_instance = nil
      puts "[ToolManager] Deactivated: #{tool_name}"
    end
  end

  # Check if any tool is active.
  #
  # @return [Boolean] true if a tool is currently active
  #
  def active?
    !@active_tool.nil?
  end

  # Get active tool name.
  #
  # @return [String, nil] Active tool name or nil
  #
  def active_tool_name
    @active_tool
  end

end # module ToolManager
end # module Shared
end # module CurvyQuads
end # module MarcelloPanicciaTools
