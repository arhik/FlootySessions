# ═══════════════════════════════════════════════════════════════════════
# Permission Modal System Example
# 
# This example demonstrates how to integrate the permission modal system
# into a UI (e.g., FlootyTUI).
# ═══════════════════════════════════════════════════════════════════════

using FlootySessions
using FlootyAbstract
using Dates

# ═══════════════════════════════════════════════════════════════════════
# Mock UI Components
# ═══════════════════════════════════════════════════════════════════════

"""
    MockUI

Simulates a UI that integrates with the permission system.
"""
mutable struct MockUI
    session::Session
    current_modal::Union{ToolPermissionRequest,Nothing}
    modal_callback::Union{Function,Nothing}
    log::Vector{String}
end

function MockUI(session::Session)
    ui = MockUI(session, nothing, nothing, String[])
    
    # Set up permission callback to automatically show modal
    store = initialize_permission_store!(session)
    register_permission_callback(store, (event, args...) -> 
        handle_permission_event(ui, event, args...)
    )
    
    ui
end

function log!(ui::MockUI, msg::String)
    push!(ui.log, "[$(now())] $msg")
    println(msg)
end

# ═══════════════════════════════════════════════════════════════════════
# Permission Event Handling
# ═══════════════════════════════════════════════════════════════════════

function handle_permission_event(ui::MockUI, event::Symbol, args...)
    if event == :request_created
        request = args[1]
        log!(ui, "📨 Permission request created: $(request.tool_name)")
        show_permission_modal!(ui, request)
    elseif event == :request_resolved
        request, response = args
        status = response.approved ? "✅ APPROVED" : "❌ DENIED"
        log!(ui, "$status: $(request.tool_name)")
    elseif event == :permission_granted
        perm = args[1]
        log!(ui, "🔓 Permission granted for $(perm.tool_name)")
    elseif event == :permission_denied
        perm = args[1]
        log!(ui, "🔒 Permission denied for $(perm.tool_name)")
    elseif event == :permission_revoked
        perm = args[1]
        log!(ui, "🔄 Permission revoked for $(perm.tool_name)")
    end
end

"""
    show_permission_modal!(ui::MockUI, request::ToolPermissionRequest)

Simulate showing a permission modal to the user.
In a real UI (e.g., FlootyTUI), this would render a modal dialog.
"""
function show_permission_modal!(ui::MockUI, request::ToolPermissionRequest)
    ui.current_modal = request
    
    # In a real UI, this would open a modal with:
    # - Tool name and description
    # - Arguments preview
    # - Allow/Deny buttons
    # - "Remember my choice" checkbox
    
    println("\n" * "="^60)
    println("🔧 TOOL PERMISSION REQUEST")
    println("="^60)
    println(format_permission_request(request))
    println("="^60)
    println()
end

"""
    user_responds_to_modal!(ui::MockUI, approved::Bool; remember::Bool=false)

Simulate the user clicking Allow or Deny in the permission modal.
"""
function user_responds_to_modal!(ui::MockUI, approved::Bool; remember::Bool=false, reason::String="")
    ui.current_modal === nothing && return nothing
    
    request = ui.current_modal
    log!(ui, "User clicked: $(approved ? "ALLOW" : "DENY") (remember=$remember)")
    
    # Submit the response
    state = submit_permission_response(
        ui.session, 
        request, 
        approved;
        remember_choice=remember,
        reason=reason
    )
    
    ui.current_modal = nothing
    
    # If approved, execute the tool
    if approved && state.executed
        result = execute_with_permission(ui.session, state)
        log!(ui, "Tool executed. Result: $(result.success ? "SUCCESS" : "FAILED")")
        return result
    elseif !approved
        log!(ui, "Tool execution cancelled by user")
        return nothing
    end
end

# ═══════════════════════════════════════════════════════════════════════
# UI Integration Examples
# ═══════════════════════════════════════════════════════════════════════

"""
    Example 1: Basic permission flow for a tool call
"""
function example_basic_permission_flow()
    println("\n" * "="^60)
    println("EXAMPLE 1: Basic Permission Flow")
    println("="^60 * "\n")
    
    # Create a session
    session = Session("Test Session")
    ui = MockUI(session)
    
    # Simulate the LLM wanting to execute a tool
    tool_name = "write"
    tool_description = "Write content to a file"
    args = Dict(
        "path" => "/tmp/test.txt",
        "content" => "Hello, World!"
    )
    
    log!(ui, "LLM requests: $tool_name($(args))")
    
    # Prepare the execution (this may trigger a permission request)
    state = prepare_tool_execution(session, tool_name, tool_description, args)
    
    if state.request !== nothing && state.response === nothing
        # UI needs to show modal and wait for user
        log!(ui, "Waiting for user permission...")
        
        # Simulate user clicking "Allow" with "Remember" checked
        result = user_responds_to_modal!(ui, true; remember=true)
        
        if result !== nothing
            println("\n📄 Tool output:")
            println(result.output)
        end
    end
end

"""
    Example 2: Using remembered permissions
"""
function example_remembered_permission()
    println("\n" * "="^60)
    println("EXAMPLE 2: Remembered Permissions")
    println("="^60 * "\n")
    
    session = Session("Test Session")
    ui = MockUI(session)
    
    # First call - should prompt
    log!(ui, "First call to 'write'...")
    state1 = prepare_tool_execution(session, "write", "Write file", 
                                     Dict("path" => "/tmp/1.txt", "content" => "1"))
    
    if state1.request !== nothing && state1.response === nothing
        log!(ui, "First call requires permission (as expected)")
        user_responds_to_modal!(ui, true; remember=true)
    end
    
    # Second call - should auto-grant due to remembered choice
    log!(ui, "\nSecond call to 'write'...")
    state2 = prepare_tool_execution(session, "write", "Write file",
                                     Dict("path" => "/tmp/2.txt", "content" => "2"))
    
    if state2.request !== nothing && state2.response !== nothing && state2.executed
        log!(ui, "✅ Second call auto-approved due to remembered permission!")
    end
    
    # Third call with different args - still auto-granted
    log!(ui, "\nThird call to 'write' (different file)...")
    state3 = prepare_tool_execution(session, "write", "Write file",
                                     Dict("path" => "/tmp/3.txt", "content" => "3"))
    
    if state3.request !== nothing && state3.response !== nothing && state3.executed
        log!(ui, "✅ Third call also auto-approved - permission applies to the tool, not the specific call!")
    end
end

"""
    Example 3: Different permission modes
"""
function example_permission_modes()
    println("\n" * "="^60)
    println("EXAMPLE 3: Permission Modes")
    println("="^60 * "\n")
    
    # Mode: prompt_each (default)
    session1 = Session("Prompt Each Mode")
    ui1 = MockUI(session1)
    set_permission_mode!(session1, "prompt_each")
    log!(ui1, "Mode: prompt_each - will ask for each tool")
    
    # Mode: auto_grant_safe
    session2 = Session("Auto Grant Safe Mode")
    ui2 = MockUI(session2)
    set_permission_mode!(session2, "auto_grant_safe")
    log!(ui2, "Mode: auto_grant_safe - safe tools (ls, pwd, read) auto-granted")
    
    # Test ls - should auto-grant
    log!(ui2, "\nCalling 'ls'...")
    state_ls = prepare_tool_execution(session2, "ls", "List directory",
                                       Dict("path" => "."))
    if state_ls.executed
        log!(ui2, "✅ 'ls' was auto-executed (safe tool)")
    end
    
    # Test write - should still prompt
    log!(ui2, "\nCalling 'write'...")
    state_write = prepare_tool_execution(session2, "write", "Write file",
                                          Dict("path" => "/tmp/x.txt", "content" => "x"))
    if state_write.request !== nothing && state_write.response === nothing
        log!(ui2, "⚠️ 'write' still requires permission (not a safe tool)")
        user_responds_to_modal!(ui2, false; reason="Don't want to write files")
    end
end

"""
    Example 4: Getting tools list for UI display
"""
function example_get_tools_for_ui()
    println("\n" * "="^60)
    println("EXAMPLE 4: Tools List for UI")
    println("="^60 * "\n")
    
    session = Session("UI Display Test")
    initialize_permission_store!(session)
    
    # Grant some permissions
    store = get_permission_store(session)
    grant_permission(store, "pwd"; duration_minutes=30)
    grant_permission(store, "ls"; duration_minutes=30)
    deny_permission(store, "shell"; reason="Security policy")
    
    # Get tools info for UI
    tools_info = get_session_tools_for_ui(session)
    
    println("Session ID: $(tools_info["session_id"])")
    println("Permission Mode: $(tools_info["permission_mode"])")
    println("\nAvailable Tools:")
    println("-" * 60)
    
    for tool in tools_info["tools"]
        status = tool["permission_status"]
        allowed = tool["allowed"] ? "✅" : "⛔"
        println("$allowed $(tool["name"]): $(tool["description"]) [Status: $status]")
    end
    
    println("\nGranted Permissions:")
    println("-" * 60)
    for perm in tools_info["granted_permissions"]
        println("🔓 $(perm["tool_name"]) - Granted at: $(perm["granted_at"])")
        if perm["expires_at"] !== nothing
            println("   Expires at: $(perm["expires_at"])")
        end
    end
end

"""
    Example 5: Revoking permissions
"""
function example_revoke_permission()
    println("\n" * "="^60)
    println("EXAMPLE 5: Revoking Permissions")
    println("="^60 * "\n")
    
    session = Session("Revoke Test")
    ui = MockUI(session)
    
    # Grant permission
    store = initialize_permission_store!(session)
    grant_permission(store, "write"; duration_minutes=60)
    log!(ui, "Granted permission for 'write' (60 min duration)")
    
    # Use it once
    log!(ui, "First call...")
    state1 = prepare_tool_execution(session, "write", "Write", 
                                     Dict("path" => "/tmp/a.txt", "content" => "a"))
    if state1.executed
        log!(ui, "✅ First call succeeded")
    end
    
    # Revoke permission
    log!(ui, "Revoking permission...")
    revoke_permission(store, "write")
    
    # Try again - should prompt
    log!(ui, "Second call after revoke...")
    state2 = prepare_tool_execution(session, "write", "Write",
                                     Dict("path" => "/tmp/b.txt", "content" => "b"))
    if state2.request !== nothing && state2.response === nothing
        log!(ui, "⚠️ Permission was revoked - user must approve again")
    end
end

"""
    Example 6: Complete UI integration pattern
    
This shows the recommended pattern for integrating with a real UI.
"""
function example_ui_integration_pattern()
    println("\n" * "="^60)
    println("EXAMPLE 6: Complete UI Integration Pattern")
    println("="^60 * "\n")
    
    session = Session("Integration Example")
    
    # 1. Initialize permission system when session starts
    initialize_permission_store!(session)
    
    # 2. Get tools for display in UI sidebar/settings
    tools_info = get_session_tools_for_ui(session)
    println("Tools available: $(length(tools_info["tools"]))")
    
    # 3. Set permission mode based on user preferences
    set_permission_mode!(session, "auto_grant_safe")
    
    # 4. When LLM wants to call a tool:
    function on_tool_call_requested(tool_name::String, args::Dict{String,Any})
        # Get tool description
        tool_desc = ""
        for tool in session.tools
            if tool.name == tool_name
                tool_desc = tool.description
                break
            end
        end
        
        # Prepare execution
        state = prepare_tool_execution(session, tool_name, tool_desc, args)
        
        if state.request !== nothing && state.response === nothing
            # Need to show permission modal
            # In real UI: render_modal(state.request)
            println("🖥️  UI shows permission modal for: $tool_name")
            println("   Arguments preview: $(state.request.arguments_preview)")
            
            # When user clicks:
            # result = wait_for_user_response()  # Blocking or async
            # Then: submit_permission_response(session, state.request, approved; remember=remember)
            # Then: execute_with_permission(session, state)
            
            return state  # UI should hold this and wait for user
        else
            # Permission already granted or denied
            if state.executed
                # Can execute immediately
                result = execute_with_permission(session, state)
                return result
            else
                # Permission denied
                println("⛔ Tool call blocked - permission denied")
                return nothing
            end
        end
    end
    
    # Simulate tool calls
    println("\nSimulating LLM tool calls:\n")
    
    # Call 1: ls (safe, auto-granted)
    println("LLM: Calling ls...")
    result1 = on_tool_call_requested("ls", Dict("path" => "."))
    
    # Call 2: write (needs permission)
    println("\nLLM: Calling write...")
    state2 = on_tool_call_requested("write", Dict("path" => "/tmp/test.txt", "content" => "Hello"))
    
    # If we got a state back, simulate user allowing it
    if state2 isa ToolExecutionState
        println("\nUser clicks ALLOW...")
        response_state = submit_permission_response(session, state2.request, true; remember=true)
        result2 = execute_with_permission(session, response_state)
        println("✅ Tool executed: $(result2.output)")
    end
end

# ═══════════════════════════════════════════════════════════════════════
# Run all examples
# ═══════════════════════════════════════════════════════════════════════

function run_all_examples()
    example_basic_permission_flow()
    example_remembered_permission()
    example_permission_modes()
    example_get_tools_for_ui()
    example_revoke_permission()
    example_ui_integration_pattern()
    
    println("\n" * "="^60)
    println("All examples completed!")
    println("="^60)
end

# Run examples if this file is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    run_all_examples()
end

# Export the examples
export example_basic_permission_flow, example_remembered_permission
export example_permission_modes, example_get_tools_for_ui
export example_revoke_permission, example_ui_integration_pattern
export run_all_examples
export MockUI, show_permission_modal!, user_responds_to_modal!