module FlootySessions

using FlootyAbstract
using FlootyAbstract: AbstractSession, AbstractAgent, AbstractTool, SessionStatus, SESSION_ACTIVE, SESSION_PAUSED, SESSION_CLOSED, AbstractPersistable, AbstractPersistenceBackend, save!, load, delete!, list
import FlootyAbstract: get_messages, add_message!
using FlootyAgents: Agent, descendants, add_child!, create_subagent, SimpleStack
using FlootyBase: Tool, ToolParameter, pwd_tool, ls_tool, read_tool, write_tool, shell_tool, diffview_tool, list_default_tools
using FlootyContextManager
using FlootyStreams: OllamaTool, OllamaFunction, web_search, web_fetch
using FlootyAbstract: AbstractSession, AbstractAgent, AbstractTool, SessionStatus, SESSION_ACTIVE, SESSION_PAUSED, SESSION_CLOSED, AbstractPersistable, AbstractPersistenceBackend, save!, load, delete!, list, search_results, result_title, result_url, result_content, fetch_title, fetch_content
using StructTypes
using UUIDs
using Dates

export Session, SessionManager, SessionData
export session_id, session_name, session_status, session_agents, session_workspace
export session_context, session_created_at, session_updated_at, session_tools
export set_active_agent!
export list_default_tools
export get_messages, add_message!

# Permission system exports
export ToolPermission, PermissionStatus, PERMISSION_PENDING, PERMISSION_GRANTED, PERMISSION_DENIED, PERMISSION_REVOKED
export ToolPermissionRequest, ToolPermissionResponse
export PermissionStore, create_permission_store
export request_tool_permission, resolve_permission_request, check_tool_permission
export grant_permission, deny_permission, revoke_permission
export initialize_permission_store!, get_permission_store
export get_available_tools_with_permissions, format_permission_request

include("session.jl")
include("manager.jl")
include("persistence.jl")
include("permissions.jl")

# Session - Mutable struct with abstract type fields
StructTypes.StructType(::Type{Session}) = StructTypes.Mutable()

# SessionStatus - serialize as Int via custom lower/construct
StructTypes.StructType(::Type{SessionStatus}) = StructTypes.CustomStruct()
StructTypes.lower(x::SessionStatus) = Int(x)
StructTypes.construct(::Type{SessionStatus}, x::Int) = SessionStatus(x)

# Tool Handlers
using IOCapture

function handle_pwd(args::Dict{String,Any}; context=nothing)
    c = IOCapture.capture() do
        println(pwd())
    end
    FlootyAbstract.ToolResult(c.output)
end

function handle_ls(args::Dict{String,Any}; context=nothing)
    path = get(args, "path", pwd())
    if !isdir(path)
        return FlootyAbstract.ToolResult(false, "", "Not a directory: $path")
    end
    c = IOCapture.capture() do
        @static if Sys.isunix()
            run(`ls -l $path`)
        else
            for file in readdir(path)
                println(file)
            end
        end
    end
    FlootyAbstract.ToolResult(c.output)
end

function handle_read(args::Dict{String,Any}; context=nothing)
    path = args["path"]
    if !isfile(path)
        return FlootyAbstract.ToolResult(false, "", "File not found: $path")
    end
    c = IOCapture.capture() do
        start_line = get(args, "start_line", nothing)
        end_line = get(args, "end_line", nothing)
        if start_line === nothing
            print(read(path, String))
        else
            lines = readlines(path)
            start_idx = max(1, start_line)
            end_idx = end_line === nothing ? length(lines) : min(end_line, length(lines))
            for line in lines[start_idx:end_idx]
                println(line)
            end
        end
    end
    FlootyAbstract.ToolResult(c.output)
end

function handle_write(args::Dict{String,Any}; context=nothing)
    path = args["path"]
    content = args["content"]
    c = IOCapture.capture() do
        start_line = get(args, "start_line", nothing)
        end_line = get(args, "end_line", nothing)
        if start_line === nothing
            write(path, content)
            println("Written to $path")
        else
            if !isfile(path)
                println(stderr, "File not found for editing: $path")
                return
            end
            lines = readlines(path)
            start_idx = max(1, start_line)
            end_idx = end_line === nothing ? length(lines) : min(end_line, length(lines))
            new_content_lines = split(content, '\n')
            new_lines = vcat(lines[1:start_idx-1], new_content_lines, lines[end_idx+1:end])
            write(path, join(new_lines, "\n"))
            println("Updated $path")
        end
    end
    FlootyAbstract.ToolResult(c.output)
end

function handle_shell(args::Dict{String,Any}; context=nothing)
    command = args["command"]
    cmd_args = get(args, "args", String[])

    c = IOCapture.capture() do
        try
            if isempty(cmd_args)
                run(`sh -c $command`)
            else
                run(`sh -c "$command $(join(cmd_args, " "))"`)
            end
        catch e
            println(stderr, "Error: $e")
        end
    end
    FlootyAbstract.ToolResult(c.output)
end

function handle_diffview(args::Dict{String,Any}; context=nothing)
    old_path = args["old_path"]
    new_path = args["new_path"]

    if !isfile(old_path)
        return FlootyAbstract.ToolResult(false, "", "Old file not found: $old_path")
    end
    if !isfile(new_path)
        return FlootyAbstract.ToolResult(false, "", "New file not found: $new_path")
    end

    c = IOCapture.capture() do
        @static if Sys.isunix()
            run(`diff -u $old_path $new_path`)
        else
            # Fallback for Windows
            old_content = read(old_path, String)
            new_content = read(new_path, String)
            println("--- $old_path")
            println("+++ $new_path")
            println("Files differ")
        end
    end
    FlootyAbstract.ToolResult(c.output)
end

# Session-level and ContextStore-level message functions
function get_messages(session::Session)
    session.root_agent === nothing && return FlootyAbstract.AbstractMessage[]
    get_messages(session.root_agent.context)
end

# Support direct ContextStore access (for agent.context)
function get_messages(ctx::FlootyContextManager.ContextStore)
    FlootyContextManager.get_messages(ctx)
end

function get_full_history(ctx::FlootyContextManager.ContextStore)
    FlootyContextManager.get_full_history(ctx)
end

function add_message!(session::Session, msg::FlootyAbstract.AbstractMessage)
    session.root_agent === nothing && return
    FlootyContextManager.add_message!(session.root_agent.context, msg)
end

# ═══════════════════════════════════════════════════════════════════════
# Permission-Aware Tool Execution
# ═══════════════════════════════════════════════════════════════════════

"""
    ToolExecutionState

Tracks the state of a tool execution that requires permission.
"""
mutable struct ToolExecutionState
    request::Union{ToolPermissionRequest,Nothing}
    response::Union{ToolPermissionResponse,Nothing}
    executed::Bool
    result::Union{FlootyAbstract.ToolResult,Nothing}
    error::String
end

ToolExecutionState() = ToolExecutionState(nothing, nothing, false, nothing, "")

"""
    prepare_tool_execution(session::Session, tool_name::String,
                          tool_description::String,
                          args::Dict{String,Any}) -> ToolExecutionState

Prepare a tool execution, checking permissions and creating a permission request if needed.
Returns a ToolExecutionState that the UI can use to show a permission modal.

Usage:
    state = prepare_tool_execution(session, "write", "Write file", args)
    if state.request !== nothing && state.response === nothing
        # Show permission modal with state.request
        # When user decides, call submit_permission_response(session, state.request, approved)
    else
        # Execute directly: execute_with_permission(session, state)
    end
"""
function prepare_tool_execution(session::Session, tool_name::String,
                               tool_description::String,
                               args::Dict{String,Any})
    state = ToolExecutionState()

    # Ensure permission store exists
    store = get_permission_store(session)
    if store === nothing
        store = initialize_permission_store!(session)
    end

    # Check current permission status
    allowed, pending_request = check_tool_permission(store, tool_name)

    if allowed
        # Permission already granted
        state.executed = true
        return state
    end

    if pending_request !== nothing
        # There's already a pending request for this tool
        state.request = pending_request
        return state
    end

    # Create a new permission request
    request = ToolPermissionRequest(session.id, tool_name, tool_description, args)
    request, auto_response = request_tool_permission(store, request)

    state.request = request

    if auto_response !== nothing
        # Auto-granted or auto-denied based on remembered choice
        state.response = auto_response
        state.executed = auto_response.approved
    end

    return state
end

"""
    submit_permission_response(session::Session, request::ToolPermissionRequest,
                              approved::Bool; kwargs...) -> ToolExecutionState

Submit a user's permission response and return the updated execution state.

Usage:
    state = prepare_tool_execution(session, ...)
    # User clicks "Allow" or "Deny"
    new_state = submit_permission_response(session, state.request, true)  # or false
    result = execute_with_permission(session, new_state)
"""
function submit_permission_response(session::Session, request::ToolPermissionRequest,
                                   approved::Bool;
                                   reason::String="",
                                   remember_choice::Bool=false)
    store = get_permission_store(session)
    store === nothing && return ToolExecutionState()

    response = ToolPermissionResponse(request, approved;
                                     reason=reason,
                                     remember_choice=remember_choice)
    resolve_permission_request(store, response)

    state = ToolExecutionState()
    state.request = request
    state.response = response
    state.executed = approved

    return state
end

"""
    execute_with_permission(session::Session, state::ToolExecutionState) -> FlootyAbstract.ToolResult

Execute a tool call after permission has been granted.
"""
function execute_with_permission(session::Session, state::ToolExecutionState)
    if !state.executed || state.request === nothing
        return FlootyAbstract.ToolResult(false, "", "Permission not granted")
    end

    tool_name = state.request.tool_name
    args = state.request.arguments

    # Get the handler from FlootyAbstract's registry
    handler = FlootyAbstract.get_tool_handler(tool_name)

    if handler === nothing
        return FlootyAbstract.ToolResult(false, "", "No handler for tool: $tool_name")
    end

    # Execute the handler
    try
        result = handler(args; context=session)
        state.result = result
        return result
    catch e
        error_msg = "Tool execution failed: $e"
        state.error = error_msg
        return FlootyAbstract.ToolResult(false, "", error_msg)
    end
end

"""
    execute_tool_with_permission(session::Session, tool_name::String,
                                args::Dict{String,Any};
                                tool_description::String="",
                                auto_execute::Bool=false) -> Union{ToolExecutionState, FlootyAbstract.ToolResult}

High-level function to execute a tool with permission checking.

If auto_execute=true and permission is already granted, returns the ToolResult directly.
Otherwise returns a ToolExecutionState for the UI to handle.
"""
function execute_tool_with_permission(session::Session, tool_name::String,
                                     args::Dict{String,Any};
                                     tool_description::String="",
                                     auto_execute::Bool=false)
    # Get tool description if not provided
    if isempty(tool_description)
        for tool in session.tools
            if tool.name == tool_name
                tool_description = tool.description
                break
            end
        end
    end

    state = prepare_tool_execution(session, tool_name, tool_description, args)

    # If auto_execute is true and we have permission, execute immediately
    if auto_execute && state.executed && state.response !== nothing
        return execute_with_permission(session, state)
    end

    # Return state for UI to handle
    return state
end

"""
    get_session_tools_for_ui(session::Session) -> Dict{String,Any}

Get all information needed by the UI to display tools and permissions.
Returns a Dict with:
    - session_id: UUID
    - tools: Vector of tool info with permission status
    - pending_requests: Vector of pending permission requests
    - permission_mode: String ("prompt_each", "remember_session", "auto_grant_safe")
"""
function get_session_tools_for_ui(session::Session)
    store = get_permission_store(session)

    result = Dict{String,Any}(
        "session_id" => string(session.id),
        "tools" => get_available_tools_with_permissions(session),
        "permission_mode" => get(session.metadata, "permission_mode", "prompt_each")
    )

    if store !== nothing
        result["pending_requests"] = [Dict(
            "request_id" => string(req.request_id),
            "tool_name" => req.tool_name,
            "tool_description" => req.tool_description,
            "arguments_preview" => req.arguments_preview,
            "created_at" => string(req.created_at),
            "timeout_seconds" => req.timeout_seconds
        ) for req in values(store.pending_requests)]

        result["granted_permissions"] = [Dict(
            "tool_name" => perm.tool_name,
            "status" => string(perm.status),
            "granted_at" => perm.granted_at !== nothing ? string(perm.granted_at) : nothing,
            "expires_at" => perm.expires_at !== nothing ? string(perm.expires_at) : nothing
        ) for perm in values(store.tool_permissions) if perm.status == PERMISSION_GRANTED]
    else
        result["pending_requests"] = []
        result["granted_permissions"] = []
    end

    result
end

"""
    set_permission_mode!(session::Session, mode::String)

Set the permission mode for a session:
    - "prompt_each": Ask for permission on each tool call (default)
    - "remember_session": Remember choices for the session duration
    - "auto_grant_safe": Auto-grant safe tools (read, ls, pwd)
    - "auto_grant_all": Auto-grant all tools (use with caution!)
"""
function set_permission_mode!(session::Session, mode::String)
    valid_modes = ["prompt_each", "remember_session", "auto_grant_safe", "auto_grant_all"]
    mode in valid_modes || throw(ArgumentError("Invalid permission mode: $mode"))

    session.metadata["permission_mode"] = mode

    store = get_permission_store(session)
    if store === nothing
        store = initialize_permission_store!(session)
    end

    if mode == "auto_grant_safe"
        # Grant safe tools for 60 minutes
        for tool in ["pwd", "ls", "read", "diffview"]
            grant_permission(store, tool; duration_minutes=60)
        end
    elseif mode == "auto_grant_all"
        # Grant all tools with no expiration
        for tool in session.tools
            grant_permission(store, tool.name)
        end
    end

    mode
end

# Web Search Handlers
function handle_web_search(args::Dict{String,Any}; context=nothing)
    query = get(args, "query", "")
    max_results = get(args, "max_results", 5)
    result = web_search(query; max_results=max_results)
    text = join(["$(result_title(r))\n$(result_url(r))\n$(first(result_content(r), 500))" 
                 for r in search_results(result)], "\n\n")
    FlootyAbstract.ToolResult(text)
end

function handle_web_fetch(args::Dict{String,Any}; context=nothing)
    url = get(args, "url", "")
    result = web_fetch(url)
    text = "$(fetch_title(result))\n\n$(fetch_content(result))"
    FlootyAbstract.ToolResult(text)
end

# ═══════════════════════════════════════════════════════════════════════
# REPL Tool Handler
# The actual execution can be delegated via callback, or uses IOCapture fallback
# ═══════════════════════════════════════════════════════════════════════

const REPL_EXECUTOR = Ref{Union{Function,Nothing}}(nothing)

"""
    set_repl_executor!(executor::Function)

Register a function to execute Julia code in the REPL.
The executor should accept (code::String) and return (success::Bool, output::String).
Called by FlootyWebUIEditor when it initializes for xterm.js integration.
"""
function set_repl_executor!(executor::Function)
    REPL_EXECUTOR[] = executor
end

"""
    default_repl_executor(code::String) -> (Bool, String)

Default executor using IOCapture in the current process.
"""
function default_repl_executor(code::String)
    isempty(strip(code)) && return (true, "")
    
    captured = IOCapture.capture(color=false) do
        try
            result = Core.eval(Main, Meta.parse(code))
            if result !== nothing
                println(result)
            end
            true
        catch e
            showerror(stderr, e, catch_backtrace())
            println(stderr)
            false
        end
    end
    
    (captured.value, captured.output)
end
function __init__()
    FlootyAbstract.register_tool_handler!("pwd", handle_pwd)
    FlootyAbstract.register_tool_handler!("ls", handle_ls)
    FlootyAbstract.register_tool_handler!("read", handle_read)
    FlootyAbstract.register_tool_handler!("write", handle_write)
    FlootyAbstract.register_tool_handler!("shell", handle_shell)
    FlootyAbstract.register_tool_handler!("diffview", handle_diffview)
    FlootyAbstract.register_tool_handler!("web_search", handle_web_search)
    FlootyAbstract.register_tool_handler!("web_fetch", handle_web_fetch)
end

end # module FlootySessions
