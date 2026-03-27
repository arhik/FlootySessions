# FlootySessions

Session management package for the Flooty multi-agent AI framework.

**Author:** Arhik <arhik23@gmail.com>

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/yourusername/FlootySessions.jl")
```

## Dependencies

- UUIDs, Dates, StructTypes
- FlootyAbstract, FlootyAgents, FlootyBase, FlootyContextManager, FlootyPermissions, FlootyPersistence, FlootyStreams, FlootyWorkspaces
- IOCapture, OrderedCollections, DiffUtils

## Overview

Manages conversational sessions between users and AI agents with support for:
- Multiple concurrent chat sessions
- Hierarchical agent structures (parent/child agents)
- Session persistence (save/load)
- Workspace management and tool integration

## Session Status Lifecycle

| Status | Description |
|--------|-------------|
| `SESSION_ACTIVE` | Currently in use |
| `SESSION_PAUSED` | Temporarily suspended |
| `SESSION_CLOSED` | Terminated |

## Core Components

- **Session** (`session.jl`) - Mutable struct for chat sessions with ID, name, status, agent hierarchy, workspace, and tools
- **SessionManager** (`manager.jl`) - Thread-safe manager for multiple sessions with locking
- **SessionData** (`persistence.jl`) - Serializable format for saving/loading sessions

## API

### Session Operations
```julia
Session(name; root_agent, workspace_folders, tools)
session_id(s), session_name(s), session_status(s)
session_agents(s), session_workspace(s), session_tools(s)
set_active_agent!(s, agent), add_agent_to_session!(s, agent)
```

### Manager Operations
```julia
SessionManager()
create_session!(manager, name; kwargs...)
get_session(manager, id), get_active_session(manager)
set_active_session!(manager, id), list_sessions(manager)
close_session!(manager, id), close_all_sessions!(manager)
```

### Persistence
```julia
SessionData(s)      # Convert to persistable format
Session(data, agent_lookup)  # Reconstruct from data
```

## Example

```julia
using FlootySessions

manager = SessionManager()
session = create_session!(manager, "My Chat"; workspace_folders=["/path/to/files"])
set_active_session!(manager, session.id)
close_session!(manager, session.id)
```

## Examples

See `examples/` directory for TUI applications and demos:
- `tui.jl` - Full TUI chat application
- `tui_diff_update.jl` - TUI with diff updates
- `diff_view_demo.jl`, `diffview_compare.jl` - Diff utilities

## Ecosystem

Part of the Flooty framework:
| Package | Purpose |
|---------|---------|
| FlootyAgents | Agent creation |
| FlootyAbstract | Abstract types |
| FlootyPersistence | Data persistence |
| FlootyWorkspaces | File management |
| FlootyStreams | Streaming |
| FlootyPermissions | Access control |
