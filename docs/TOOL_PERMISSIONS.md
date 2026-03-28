# Tool Permission Modal System

## Overview

This permission system allows the UI to request user approval before executing tool calls. Sessions send their available tools list, and the UI displays a permission modal for each tool call that requires authorization.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              SESSION                                     │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────┐ │
│  │   Session       │───▶│ PermissionStore │───▶│ ToolExecutionState  │ │
│  │   (tools list)  │    │ (permissions)   │    │ (request/response)│ │
│  └─────────────────┘    └─────────────────┘    └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              UI (Client)                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────┐ │
│  │ get_session_    │───▶│ Permission Modal│───▶│ submit_permission_  │ │
│  │ tools_for_ui()  │    │ (display)       │    │ response()          │ │
│  └─────────────────┘    └─────────────────┘    └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

## Key Components

### 1. PermissionStore

Stores permission state for a session:
- `tool_permissions`: Current permission status for each tool
- `pending_requests`: Permission requests awaiting user response
- `default_policy`: Default permission policy per tool

### 2. ToolPermissionRequest

Created when a tool needs permission:
- `request_id`: Unique identifier
- `session_id`: Session requesting permission
- `tool_name`: Tool to execute
- `tool_description`: Human-readable description
- `arguments`: Arguments to pass to tool
- `arguments_preview`: Truncated preview for display
- `timeout_seconds`: How long to wait for user response

### 3. ToolPermissionResponse

User's decision:
- `request_id`: Links to the request
- `approved`: true/false
- `remember_choice`: Whether to remember for session
- `reason`: Optional reason for denial

### 4. ToolExecutionState

Tracks execution state:
- `request`: The permission request
- `response`: User's response (if received)
- `executed`: Whether execution is allowed
- `result`: Tool execution result

## Usage Flow

### Step 1: Initialize Permission System

```julia
session = Session("My Session")
initialize_permission_store!(session)

# Optional: Set permission mode
set_permission_mode!(session, "auto_grant_safe")
```

### Step 2: Get Tools List for UI

```julia
tools_info = get_session_tools_for_ui(session)
```

### Step 3: Handle Tool Call

```julia
state = prepare_tool_execution(session, "write", "Write file", args)

if state.request !== nothing && state.response === nothing
    show_permission_modal(state.request)
else
    result = execute_with_permission(session, state)
end
```

### Step 4: Handle User Response

```julia
new_state = submit_permission_response(session, request, approved; remember_choice=true)
if approved
    result = execute_with_permission(session, new_state)
end
```

## Permission Modes

1. **prompt_each** (Default): Ask for every tool call
2. **remember_session**: Ask once, remember for session
3. **auto_grant_safe**: Auto-grant read-only tools (ls, pwd, read, diffview)
4. **auto_grant_all**: Auto-grant all tools (use with caution!)

## Files

- `src/permissions.jl`: Core permission system
- `src/FlootySessions.jl`: Integration with Session
- `examples/permissions_demo.jl`: Usage examples
