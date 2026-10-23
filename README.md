# FlootySessions.jl

[![Julia Version](https://img.shields.io/badge/julia-%E2%89%A51.11-blue.svg)](https://julialang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Session management for multi-agent AI conversations** in the Flooty ecosystem.

FlootySessions.jl provides robust session lifecycle management with thread-safe operations, hierarchical agent structures, fine-grained tool permissions, and persistence capabilities. It serves as the core session layer for building interactive AI applications with Julia.

---

## 📋 Table of Contents

- [Overview](#overview)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Features](#features)
- [Architecture](#architecture)
- [API Reference](#api-reference)
- [Session Lifecycle](#session-lifecycle)
- [Tool System](#tool-system)
- [Permission System](#permission-system)
- [Persistence](#persistence)
- [Examples](#examples)
- [Flooty Ecosystem](#flooty-ecosystem)
- [Development](#development)
- [License](#license)

---

## 🔍 Overview

**FlootySessions.jl** manages conversational sessions between users and AI agents in a multi-agent system. Each session represents a conversation context that can contain:

- **Multiple agents** organized in a hierarchical tree structure
- **Tool integrations** with permission-based access control
- **Workspace folders** for file operations
- **Message history** with persistence support
- **Thread-safe operations** for concurrent access

### Design Philosophy

- **Modularity**: Clean separation between session, manager, and permission concerns
- **Safety**: Thread-safe operations with ReentrantLock for concurrent access
- **Extensibility**: Plugin-based tool system with permission controls
- **Persistence**: JSON-serializable session data for save/load operations

---

## 📦 Installation

```julia
using Pkg
Pkg.add(url="https://github.com/yourusername/FlootySessions.jl")
```

### Requirements

- Julia ≥ 1.11
- Flooty ecosystem packages (see [Project.toml](Project.toml))

### Dependencies

| Package | Purpose |
|---------|---------|
| `FlootyAbstract` | Abstract types and interfaces |
| `FlootyAgents` | Agent creation and hierarchy management |
| `FlootyBase` | Core tool definitions and handlers |
| `FlootyContextManager` | Message context and history |
| `FlootyPermissions` | Access control interfaces |
| `FlootyPersistence` | Data persistence layer |
| `FlootyWorkspaces` | File/workspace management |
| `FlootyStreams` | Streaming capabilities |
| `StructTypes` | Serialization support |
| `UUIDs` | Unique identifiers |
| `Dates` | Timestamp management |
| `IOCapture` | Tool output capture |

---

## 🚀 Quick Start

```julia
using FlootySessions

# Create a session manager
manager = SessionManager()

# Create a new session with workspace
session = create_session!(
    manager,
    "My Chat Session";
    workspace_folders=["/path/to/project"]
)

# Set as active session
set_active_session!(manager, session.id)

# Get the active session
active = get_active_session(manager)

# List all sessions
all_sessions = list_sessions(manager)

# Cleanup when done
close_session!(manager, session.id)
```

### Agent Hierarchy Example

```julia
using FlootySessions, FlootyAgents

# Create a session with a root agent
root = Agent("Assistant")
session = Session("Multi-Agent Chat"; root_agent=root)

# Add sub-agents
planner = create_subagent_in_session!(session, root, "Planner")
coder = create_subagent_in_session!(session, root, "Coder")

# Switch active agent
set_active_agent!(session, coder)

# Get all agents in session
agents = session_agents(session)
```

---

## ✨ Features

### Core Capabilities

| Feature | Description |
|---------|-------------|
| **Session Lifecycle** | Create, pause, resume, close sessions with status tracking |
| **Thread Safety** | All manager operations use ReentrantLock for concurrent access |
| **Agent Hierarchy** | Parent-child agent relationships with active agent tracking |
| **Workspace Management** | Scoped file access with folder restrictions |
| **Tool System** | Built-in + custom tools with JSON Schema definitions |
| **Permission Control** | Fine-grained tool execution permissions with modal UI support |
| **Persistence** | Save/load sessions with JSON serialization |
| **Message Context** | Integration with FlootyContextManager for conversation history |

### Built-in Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| `pwd` | Print working directory | None |
| `ls` | List directory contents | `path` (optional) |
| `read` | Read file contents | `path`, `start_line`, `end_line` |
| `write` | Write or edit files | `path`, `content`, `start_line`, `end_line` |
| `shell` | Execute shell commands | `command`, `args` |
| `diffview` | Show diff between files | `old_path`, `new_path` |

---

## 🏗️ Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SessionManager                               │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Thread-safe session registry (Dict{UUID, Session})          │   │
│  │  - ReentrantLock for concurrent access                       │   │
│  │  - Active session tracking                                   │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
            ┌──────────┐    ┌──────────┐   ┌──────────┐
            │ Session 1 │    │ Session 2 │   │ Session N│
            └──────────┘    └──────────┘   └──────────┘
                    │               │               │
        ┌───────────┼───────────┐   │               │
        ▼           ▼           ▼   ▼               ▼
   ┌────────┐ ┌──────────┐ ┌──────────────┐  ┌──────────────┐
   │ Agent  │ │Workspace │ │ PermissionStore│ │   Context    │
   │ Tree   │ │ Folders  │ │                │ │   Store      │
   └────────┘ └──────────┘ └──────────────┘  └──────────────┘
```

### Key Components

#### 1. Session (`Session`)

The core data structure representing a conversation:

```julia
mutable struct Session <: AbstractSession
    id::UUID                          # Unique identifier
    name::String                      # Human-readable name
    status::SessionStatus             # ACTIVE, PAUSED, or CLOSED
    root_agent::Union{AbstractAgent,Nothing}  # Root of agent hierarchy
    active_agent_id::Union{UUID,Nothing}      # Currently active agent
    workspace_folders::Vector{String}       # Allowed file paths
    tools::Vector{AbstractTool}              # Available tools
    metadata::Dict{String,Any}               # Custom metadata
    created_at::DateTime
    updated_at::DateTime
end
```

#### 2. SessionManager (`SessionManager`)

Thread-safe manager for multiple sessions:

```julia
mutable struct SessionManager <: AbstractSessionManager
    sessions::Dict{UUID,Session}      # Session registry
    active_session_id::Union{UUID,Nothing}  # Currently active
    lock::ReentrantLock                 # Thread safety
end
```

#### 3. PermissionStore (`PermissionStore`)

Manages tool execution permissions:

```julia
mutable struct PermissionStore
    session_id::UUID
    tool_permissions::Dict{String,ToolPermission}
    pending_requests::Dict{UUID,ToolPermissionRequest}
    request_responses::Dict{UUID,ToolPermissionResponse}
    default_policy::Dict{String,PermissionStatus}
    callbacks::Vector{Function}
end
```

---

## 📖 API Reference

### Session Management

#### Creating Sessions

```julia
# Create a session manager
manager = SessionManager()

# Create a new session
session = create_session!(manager, name::String;
    root_agent=nothing,           # Root agent (optional)
    workspace_folders=String[],   # Allowed directories
    tools=list_default_tools()     # Available tools
)

# Direct construction
session = Session(name::String;
    root_agent=nothing,
    workspace_folders=String[],
    tools=list_default_tools()
)
```

#### Session Lifecycle

```julia
# Status transitions
pause_session(s::Session)     # -> SESSION_PAUSED
resume_session(s::Session)    # -> SESSION_ACTIVE
close_session(s::Session)     # -> SESSION_CLOSED

# Manager operations
close_session!(manager, session_id::UUID)     # Remove from manager
close_all_sessions!(manager)                   # Cleanup all
```

#### Session Access

```julia
# Getters
session_id(s)          # UUID
session_name(s)        # String
session_status(s)      # SessionStatus
session_agents(s)      # Vector{AbstractAgent}
session_workspace(s)   # Vector{String}
session_tools(s)       # Vector{AbstractTool}
session_context(s)     # Dict{String,Any}
session_created_at(s)  # DateTime
session_updated_at(s)  # DateTime

# Manager operations
get_session(manager, session_id::UUID)         # Get by ID
get_active_session(manager)                     # Get active
set_active_session!(manager, session_id::UUID) # Set active
list_sessions(manager)                          # Get all sessions
```

#### Agent Management

```julia
# Add agents
add_agent_to_session!(s::Session, agent::AbstractAgent)
create_subagent_in_session!(s::Session, parent::AbstractAgent, name::String; kwargs...)

# Agent navigation
set_active_agent!(s::Session, agent::AbstractAgent)
get_active_agent(s::Session)
get_agent_from_session(s::Session, agent_id::UUID)
remove_agent_from_session!(s::Session, agent_id::UUID)

# Get all agents (root + descendants)
agents = session_agents(s)
```

#### Message Operations

```julia
# Get conversation history
messages = get_messages(session::Session)

# Add a message
add_message!(session::Session, msg::AbstractMessage)
```

---

## 🔄 Session Lifecycle

### Session States

```julia
@enum SessionStatus begin
    SESSION_ACTIVE   # Currently in use
    SESSION_PAUSED   # Temporarily suspended
    SESSION_CLOSED   # Terminated
end
```

### State Transitions

```
                    ┌─────────────┐
         ┌─────────│   ACTIVE    │◀────────┐
         │         └─────────────┘         │
    close│              │ pause            │ resume
         │              ▼                  │
         │         ┌─────────────┐         │
         │         │   PAUSED    │─────────┘
         │         └─────────────┘
         │              │
         └──────────────┘
                          close
```

### Lifecycle Example

```julia
manager = SessionManager()

# Create
session = create_session!(manager, "Project Chat")
# Status: SESSION_ACTIVE

# Pause
pause_session(session)
# Status: SESSION_PAUSED

# Resume
resume_session(session)
# Status: SESSION_ACTIVE

# Close
close_session!(manager, session.id)
# Status: SESSION_CLOSED (removed from manager)
```

---

## 🔧 Tool System

### Tool Handlers

Tools are registered with the global registry in `__init__()`:

```julia
function __init__()
    FlootyAbstract.register_tool_handler!("pwd", handle_pwd)
    FlootyAbstract.register_tool_handler!("ls", handle_ls)
    FlootyAbstract.register_tool_handler!("read", handle_read)
    FlootyAbstract.register_tool_handler!("write", handle_write)
    FlootyAbstract.register_tool_handler!("shell", handle_shell)
    FlootyAbstract.register_tool_handler!("diffview", handle_diffview)
end
```

### Handler Signature

```julia
function handle_toolname(args::Dict{String,Any}; context=nothing) -> ToolResult
```

### Built-in Tool Examples

#### Read Tool

```julia
# Read entire file
result = handle_read(Dict("path" => "/path/to/file.jl"))

# Read specific lines
result = handle_read(Dict(
    "path" => "/path/to/file.jl",
    "start_line" => 10,
    "end_line" => 50
))
```

#### Write Tool

```julia
# Write entire file
result = handle_write(Dict(
    "path" => "/path/to/file.jl",
    "content" => "# New content"
))

# Edit specific lines (replace lines 10-20)
result = handle_write(Dict(
    "path" => "/path/to/file.jl",
    "content" => "# Replacement content",
    "start_line" => 10,
    "end_line" => 20
))
```

#### Shell Tool

```julia
# Simple command
result = handle_shell(Dict("command" => "pwd"))

# With arguments
result = handle_shell(Dict(
    "command" => "ls",
    "args" => ["-la", "/path/to/dir"]
))
```

---

## 🛡️ Permission System

### Overview

The permission system allows fine-grained control over tool execution:

1. **Permission Request**: Created when tool call needs approval
2. **Permission Response**: User's approve/deny decision
3. **Permission Store**: Tracks granted/denied permissions per session

### Permission States

```julia
@enum PermissionStatus begin
    PERMISSION_PENDING   # Waiting for user decision
    PERMISSION_GRANTED   # User approved
    PERMISSION_DENIED    # User denied
    PERMISSION_REVOKED   # Previously granted but revoked
end
```

### Permission Modes

| Mode | Description |
|------|-------------|
| `prompt_each` | Ask for permission on every tool call (default) |
| `remember_session` | Ask once, remember for session duration |
| `auto_grant_safe` | Auto-grant read-only tools (pwd, ls, read, diffview) |
| `auto_grant_all` | Auto-grant all tools (use with caution!) |

### Usage Flow

```julia
# Initialize permission store
initialize_permission_store!(session)

# Set permission mode
set_permission_mode!(session, "auto_grant_safe")

# Prepare tool execution (checks permissions)
state = prepare_tool_execution(session, "write", "Write file", args)

# If permission needed
if state.request !== nothing && state.response === nothing
    # Show modal to user with state.request
    # ... user decides ...
    new_state = submit_permission_response(session, state.request, true)
end

# Execute with permission
result = execute_with_permission(session, state)
```

### UI Integration

```julia
# Get all tools with permission status for UI
tools_info = get_session_tools_for_ui(session)

# Returns Dict with:
# - session_id: UUID string
# - tools: Vector of tool info with permission_status
# - pending_requests: Active permission requests
# - permission_mode: Current mode
```

### Direct Permission Management

```julia
store = get_permission_store(session)

# Grant permission
grant_permission(store, "write"; duration_minutes=60)

# Deny permission
deny_permission(store, "shell"; reason="Security policy")

# Revoke permission
revoke_permission(store, "write")

# Check permission
allowed, pending = check_tool_permission(store, "write")
```

---

## 💾 Persistence

### SessionData Structure

```julia
mutable struct SessionData <: AbstractPersistable
    id::UUID
    name::String
    status::Int               # Serialized as Int
    root_agent_id::Union{UUID,Nothing}
    active_agent_id::Union{UUID,Nothing}
    workspace_folders::Vector{String}
    metadata::Dict{String,Any}
    created_at::DateTime
    updated_at::DateTime
end
```

### Save/Load Flow

```julia
# Convert session to persistable data
data = SessionData(session)

# Serialize (using FlootyPersistence)
save!(backend, data)

# Deserialize and reconstruct
loaded_data = load(backend, session_id)
agent_lookup = load_agents(backend)  # Load associated agents
session = Session(loaded_data, agent_lookup)
```

### Serialization Support

The module uses `StructTypes` for JSON serialization:

```julia
StructTypes.StructType(::Type{Session}) = StructTypes.Mutable()
StructTypes.StructType(::Type{SessionData}) = StructTypes.Mutable()
StructTypes.StructType(::Type{SessionStatus}) = StructTypes.CustomStruct()
StructTypes.lower(x::SessionStatus) = Int(x)
StructTypes.construct(::Type{SessionStatus}, x::Int) = SessionStatus(x)
```

---

## 💡 Examples

### Basic Session Management

```julia
using FlootySessions

manager = SessionManager()

# Create multiple sessions
session1 = create_session!(manager, "Project A"; workspace_folders=["/projects/a"])
session2 = create_session!(manager, "Project B"; workspace_folders=["/projects/b"])

# Switch between sessions
set_active_session!(manager, session1.id)
# ... work on Project A ...

set_active_session!(manager, session2.id)
# ... work on Project B ...

# List all sessions
for s in list_sessions(manager)
    println("$(session_name(s)): $(session_status(s))")
end

# Cleanup
close_all_sessions!(manager)
```

### Permission-Aware Tool Execution

```julia
using FlootySessions

session = Session("Safe Session")
initialize_permission_store!(session)
set_permission_mode!(session, "auto_grant_safe")

# Execute tool with permission checking
state = execute_tool_with_permission(
    session,
    "write",
    Dict("path" => "test.txt", "content" => "Hello");
    tool_description="Write test file",
    auto_execute=false  # Return state for UI handling
)

if state isa ToolExecutionState
    # Show permission modal
    display_permission_modal(state.request)
    
    # After user decision
    approved = get_user_approval()
    new_state = submit_permission_response(session, state.request, approved)
    result = execute_with_permission(session, new_state)
else
    # Direct result (permission already granted)
    result = state
end
```

### Agent Hierarchy

```julia
using FlootySessions, FlootyAgents

# Create root agent
root = Agent("Project Manager")
session = Session("Team Chat"; root_agent=root)

# Create specialized sub-agents
architect = create_subagent_in_session!(session, root, "Architect")
developer = create_subagent_in_session!(session, root, "Developer")
tester = create_subagent_in_session!(session, root, "Tester")

# Work with specific agent
set_active_agent!(session, developer)

# Get conversation history for current agent
messages = get_messages(session)

# All agents in session
for agent in session_agents(session)
    println("Agent: $(agent.name)")
end
```

See the `examples/` directory for complete working examples:

- `permissions_demo.jl` - Permission system demonstration
- `diff_view_demo.jl` - File comparison functionality
- `tui.jl` - Full terminal user interface (TUI) application

---

## 🌐 Flooty Ecosystem

FlootySessions.jl is part of the **Flooty** multi-agent AI framework:

| Package | Purpose | Relationship |
|---------|---------|--------------|
| **FlootyAbstract** | Abstract types and interfaces | Core dependency |
| **FlootyAgents** | Agent creation and hierarchy | Agent management |
| **FlootyBase** | Tool definitions and handlers | Tool system |
| **FlootyContextManager** | Message context and history | Conversation storage |
| **FlootyPermissions** | Access control interfaces | Permission base |
| **FlootyPersistence** | Data persistence layer | Save/load |
| **FlootyWorkspaces** | File/workspace management | File operations |
| **FlootyStreams** | Streaming capabilities | LLM streaming |
| **FlootyTUI** | Terminal user interface | Client application |

### Architecture Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                         User Interface                          │
│                    (FlootyTUI / Web / API)                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      FlootySessions.jl                          │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────┐    │
│  │  Session    │  │  Permission  │  │    SessionManager   │    │
│  │  (context)  │◀─┤    Store     │◀─┤  (lifecycle, lock)  │    │
│  └─────────────┘  └──────────────┘  └─────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│FlootyAgents  │      │FlootyContext │      │FlootyBase    │
│(hierarchy)   │      │  Manager     │      │(tools)       │
└──────────────┘      └──────────────┘      └──────────────┘
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      FlootyStreams / LLM                         │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🔨 Development

### Code Change Protocol

See [`.cursorrules`](.cursorrules) for development guidelines:

1. **Present a diff view** before any code edit
2. **Explain the rationale** for the change
3. **Wait for confirmation** before applying

### Change Scope Rules

- ✅ One function at a time -or- One struct at a time
- ❌ Never bulk edit multiple unrelated functions
- ❌ Never modify more than 50 lines at once
- ❌ Never change files without showing diff first

### Testing

```julia
using FlootySessions
using Test

# Run tests
include("test/runtests.jl")
```

### Project Structure

```
FlootySessions.jl/
├── src/
│   ├── FlootySessions.jl    # Main module with tool handlers
│   ├── session.jl           # Session struct and operations
│   ├── manager.jl           # SessionManager implementation
│   ├── persistence.jl       # Serialization support
│   └── permissions.jl       # Permission system
├── examples/
│   ├── tui.jl               # Full TUI application
│   ├── permissions_demo.jl  # Permission system demo
│   ├── diff_view_demo.jl    # Diff view functionality
│   └── sample_code/         # Sample files for testing
├── docs/
│   └── TOOL_PERMISSIONS.md  # Permission system documentation
├── test/                    # Test suite
├── Project.toml             # Dependencies
├── summary.md               # Project summary
├── tools.md                 # Dynamic tools architecture
├── GAP_ANALYSIS.md          # TUI gap analysis
└── README.md                # This file
```

---

## 📄 License

MIT License - see LICENSE file for details.

**Author**: Arhik (arhik23@gmail.com)

**Repository**: https://github.com/yourusername/FlootySessions.jl

---

## 🙏 Acknowledgments

This package is part of the Flooty multi-agent AI framework built with Julia. Special thanks to the Julia community for the excellent ecosystem and libraries that make this possible.

---

*Generated for FlootySessions.jl - Session management for multi-agent AI conversations*