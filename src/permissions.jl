# ═══════════════════════════════════════════════════════════════════════
# Tool Permission System
# ═══════════════════════════════════════════════════════════════════════

using Dates
using UUIDs

export ToolPermission, PermissionStatus, PERMISSION_PENDING, PERMISSION_GRANTED, PERMISSION_DENIED, PERMISSION_REVOKED
export ToolPermissionRequest, ToolPermissionResponse
export PermissionStore, create_permission_store
export request_tool_permission, resolve_permission_request, check_tool_permission
export get_pending_requests, grant_permission, deny_permission, revoke_permission
export get_session_tool_permissions, set_tool_permission_default

@enum PermissionStatus begin
    PERMISSION_PENDING   # Waiting for user decision
    PERMISSION_GRANTED   # User approved this tool call
    PERMISSION_DENIED    # User denied this tool call
    PERMISSION_REVOKED   # Previously granted but now revoked
end

"""
    ToolPermission

Represents the permission state for a specific tool in a session.
"""
mutable struct ToolPermission
    tool_name::String
    status::PermissionStatus
    granted_at::Union{DateTime,Nothing}
    expires_at::Union{DateTime,Nothing}  # Optional expiration
    metadata::Dict{String,Any}           # Extra info (user_id, reason, etc.)
    
    function ToolPermission(tool_name::String; 
                           status::PermissionStatus=PERMISSION_PENDING,
                           granted_at::Union{DateTime,Nothing}=nothing,
                           expires_at::Union{DateTime,Nothing}=nothing,
                           metadata::Dict{String,Any}=Dict{String,Any}())
        new(tool_name, status, granted_at, expires_at, metadata)
    end
end

"""
    ToolPermissionRequest

Sent from session to UI when a tool call needs permission.
"""
mutable struct ToolPermissionRequest
    request_id::UUID
    session_id::UUID
    tool_name::String
    tool_description::String
    arguments::Dict{String,Any}
    arguments_preview::String  # Human-readable preview of args
    created_at::DateTime
    timeout_seconds::Int       # How long to wait for user response
    
    function ToolPermissionRequest(session_id::UUID, tool_name::String,
                                   tool_description::String,
                                   arguments::Dict{String,Any};
                                   timeout_seconds::Int=300)
        # Create a human-readable preview of arguments
        preview = _create_args_preview(arguments)
        
        new(uuid4(), session_id, tool_name, tool_description,
            arguments, preview, now(), timeout_seconds)
    end
end

"""
    ToolPermissionResponse

Sent from UI back to session with user's decision.
"""
mutable struct ToolPermissionResponse
    request_id::UUID
    session_id::UUID
    tool_name::String
    approved::Bool
    approved_at::DateTime
    reason::String           # Optional reason for denial
    remember_choice::Bool    # Whether to remember this choice for session
    
    function ToolPermissionResponse(request::ToolPermissionRequest, approved::Bool;
                                   reason::String="", remember_choice::Bool=false)
        new(request.request_id, request.session_id, request.tool_name,
            approved, now(), reason, remember_choice)
    end
end

"""
    PermissionStore

Manages permission state for a session.
"""
mutable struct PermissionStore
    session_id::UUID
    tool_permissions::Dict{String,ToolPermission}      # Tool name -> permission
    pending_requests::Dict{UUID,ToolPermissionRequest} # Request ID -> request
    request_responses::Dict{UUID,ToolPermissionResponse} # Request ID -> response
    default_policy::Dict{String,PermissionStatus}      # Default policy per tool
    callbacks::Vector{Function}                        # Callbacks for permission events
    
    function PermissionStore(session_id::UUID)
        new(session_id, 
            Dict{String,ToolPermission}(),
            Dict{UUID,ToolPermissionRequest}(),
            Dict{UUID,ToolPermissionResponse}(),
            Dict{String,PermissionStatus}(),
            Function[])
    end
end

"""
    create_permission_store(session_id::UUID) -> PermissionStore

Create a new permission store for a session.
"""
function create_permission_store(session_id::UUID)
    PermissionStore(session_id)
end

# ═══════════════════════════════════════════════════════════════════════
# Permission Request Lifecycle
# ═══════════════════════════════════════════════════════════════════════

"""
    request_tool_permission(store::PermissionStore, request::ToolPermissionRequest) -> ToolPermissionRequest

Register a new permission request. Returns the request with generated ID.
"""
function request_tool_permission(store::PermissionStore, request::ToolPermissionRequest)
    # Check if we already have a remembered decision
    if haskey(store.tool_permissions, request.tool_name)
        perm = store.tool_permissions[request.tool_name]
        if perm.status == PERMISSION_GRANTED && !_is_expired(perm)
            # Auto-grant based on remembered permission
            response = ToolPermissionResponse(request, true; remember_choice=true)
            store.request_responses[request.request_id] = response
            return request, response
        elseif perm.status == PERMISSION_DENIED
            # Auto-deny based on remembered decision
            response = ToolPermissionResponse(request, false; 
                reason="Previously denied for this session", remember_choice=true)
            store.request_responses[request.request_id] = response
            return request, response
        end
    end
    
    # Store the pending request
    store.pending_requests[request.request_id] = request
    
    # Notify callbacks
    for cb in store.callbacks
        try
            cb(:request_created, request)
        catch e
            @warn "Permission callback failed" exception=e
        end
    end
    
    return request, nothing
end

"""
    resolve_permission_request(store::PermissionStore, response::ToolPermissionResponse) -> Bool

Resolve a pending request with a user response. Returns true if request was found.
"""
function resolve_permission_request(store::PermissionStore, response::ToolPermissionResponse)
    # Remove from pending
    request = pop!(store.pending_requests, response.request_id, nothing)
    request === nothing && return false
    
    # Store the response
    store.request_responses[response.request_id] = response
    
    # Update tool permission if remembered
    if response.remember_choice
        perm = ToolPermission(response.tool_name;
            status=response.approved ? PERMISSION_GRANTED : PERMISSION_DENIED,
            granted_at=response.approved_at,
            metadata=Dict{String,Any}("reason" => response.reason))
        store.tool_permissions[response.tool_name] = perm
    end
    
    # Notify callbacks
    for cb in store.callbacks
        try
            cb(:request_resolved, request, response)
        catch e
            @warn "Permission callback failed" exception=e
        end
    end
    
    return true
end

"""
    check_tool_permission(store::PermissionStore, tool_name::String) -> Tuple{Bool, Union{ToolPermissionRequest,Nothing}}

Check if a tool has permission to execute. Returns (allowed, request_if_pending).
"""
function check_tool_permission(store::PermissionStore, tool_name::String)
    # Check for existing permission
    if haskey(store.tool_permissions, tool_name)
        perm = store.tool_permissions[tool_name]
        if perm.status == PERMISSION_GRANTED && !_is_expired(perm)
            return true, nothing
        elseif perm.status == PERMISSION_DENIED
            return false, nothing
        end
    end
    
    # Check for pending requests for this tool
    for (_, request) in store.pending_requests
        if request.tool_name == tool_name
            return false, request
        end
    end
    
    # No decision made yet - caller should create a request
    return false, nothing
end

# ═══════════════════════════════════════════════════════════════════════
# Permission Management
# ═══════════════════════════════════════════════════════════════════════

"""
    grant_permission(store::PermissionStore, tool_name::String; 
                     duration_minutes::Union{Int,Nothing}=nothing,
                     metadata::Dict{String,Any}=Dict()) -> ToolPermission

Grant permission for a tool. Optionally specify duration in minutes.
"""
function grant_permission(store::PermissionStore, tool_name::String;
                         duration_minutes::Union{Int,Nothing}=nothing,
                         metadata::Dict{String,Any}=Dict{String,Any}())
    expires = duration_minutes !== nothing ? now() + Minute(duration_minutes) : nothing
    perm = ToolPermission(tool_name;
        status=PERMISSION_GRANTED,
        granted_at=now(),
        expires_at=expires,
        metadata=metadata)
    store.tool_permissions[tool_name] = perm
    
    # Notify callbacks
    for cb in store.callbacks
        try
            cb(:permission_granted, perm)
        catch e
            @warn "Permission callback failed" exception=e
        end
    end
    
    perm
end

"""
    deny_permission(store::PermissionStore, tool_name::String; 
                   reason::String="") -> ToolPermission

Deny permission for a tool.
"""
function deny_permission(store::PermissionStore, tool_name::String; reason::String="")
    perm = ToolPermission(tool_name;
        status=PERMISSION_DENIED,
        metadata=Dict{String,Any}("reason" => reason))
    store.tool_permissions[tool_name] = perm
    
    # Notify callbacks
    for cb in store.callbacks
        try
            cb(:permission_denied, perm)
        catch e
            @warn "Permission callback failed" exception=e
        end
    end
    
    perm
end

"""
    revoke_permission(store::PermissionStore, tool_name::String) -> Bool

Revoke a previously granted permission. Returns true if permission existed.
"""
function revoke_permission(store::PermissionStore, tool_name::String)
    haskey(store.tool_permissions, tool_name) || return false
    perm = store.tool_permissions[tool_name]
    perm.status = PERMISSION_REVOKED
    perm.granted_at = nothing
    perm.expires_at = nothing
    
    # Notify callbacks
    for cb in store.callbacks
        try
            cb(:permission_revoked, perm)
        catch e
            @warn "Permission callback failed" exception=e
        end
    end
    
    true
end

"""
    set_tool_permission_default(store::PermissionStore, tool_name::String, 
                                default::PermissionStatus)

Set the default permission policy for a tool.
"""
function set_tool_permission_default(store::PermissionStore, tool_name::String, 
                                   default::PermissionStatus)
    store.default_policy[tool_name] = default
end

"""
    get_pending_requests(store::PermissionStore) -> Vector{ToolPermissionRequest}

Get all pending permission requests.
"""
function get_pending_requests(store::PermissionStore)
    collect(values(store.pending_requests))
end

"""
    get_session_tool_permissions(store::PermissionStore) -> Vector{ToolPermission}

Get all tool permissions for the session.
"""
function get_session_tool_permissions(store::PermissionStore)
    collect(values(store.tool_permissions))
end

"""
    register_permission_callback(store::PermissionStore, callback::Function)

Register a callback for permission events. Callback receives (event_type, args...).
Events: :request_created, :request_resolved, :permission_granted, :permission_denied, :permission_revoked
"""
function register_permission_callback(store::PermissionStore, callback::Function)
    push!(store.callbacks, callback)
end

# ═══════════════════════════════════════════════════════════════════════
# Session Integration
# ═══════════════════════════════════════════════════════════════════════

"""
    get_permission_store(session::Session) -> Union{PermissionStore,Nothing}

Get the permission store from a session's metadata.
"""
function get_permission_store(session::Session)
    get(session.metadata, "permission_store", nothing)
end

"""
    initialize_permission_store!(session::Session) -> PermissionStore

Create and attach a permission store to a session.
"""
function initialize_permission_store!(session::Session)
    store = create_permission_store(session.id)
    session.metadata["permission_store"] = store
    
    # Set default permissions based on session settings
    if get(session.metadata, "auto_grant_safe_tools", false)
        # Auto-grant safe tools like pwd, ls
        for tool in ["pwd", "ls", "read"]
            set_tool_permission_default(store, tool, PERMISSION_GRANTED)
            grant_permission(store, tool; duration_minutes=60)
        end
    end
    
    store
end

# ═══════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════

function _is_expired(perm::ToolPermission)
    perm.expires_at === nothing && return false
    return now() > perm.expires_at
end

function _create_args_preview(args::Dict{String,Any}; max_length::Int=200)
    isempty(args) && return "No arguments"
    
    parts = String[]
    for (key, val) in args
        val_str = string(val)
        if length(val_str) > 50
            val_str = val_str[1:47] * "..."
        end
        push!(parts, "$key=$val_str")
    end
    
    preview = join(parts, ", ")
    if length(preview) > max_length
        preview = preview[1:max_length-3] * "..."
    end
    
    preview
end

"""
    format_permission_request(request::ToolPermissionRequest) -> String

Create a human-readable formatted string for a permission request.
"""
function format_permission_request(request::ToolPermissionRequest)
    """
    🔧 Tool Call Request
    
    Session: $(request.session_id)
    Tool: $(request.tool_name)
    Description: $(request.tool_description)
    
    Arguments:
    $(request.arguments_preview)
    
    Timeout: $(request.timeout_seconds)s
    """
end

"""
    get_available_tools_with_permissions(session::Session) -> Vector{Dict{String,Any}}

Get all available tools for a session with their current permission status.
This is what the UI should call to display the tools list.
"""
function get_available_tools_with_permissions(session::Session)
    tools = session_tools(session)
    store = get_permission_store(session)
    
    result = Dict{String,Any}[]
    for tool in tools
        tool_dict = Dict{String,Any}(
            "name" => tool.name,
            "description" => tool.description,
            "parameters" => tool.parameters,
        )
        
        if store !== nothing
            allowed, _ = check_tool_permission(store, tool.name)
            perm = get(store.tool_permissions, tool.name, nothing)
            tool_dict["permission_status"] = perm !== nothing ? string(perm.status) : "PENDING"
            tool_dict["allowed"] = allowed
        else
            tool_dict["permission_status"] = "UNKNOWN"
            tool_dict["allowed"] = false
        end
        
        push!(result, tool_dict)
    end
    
    result
end