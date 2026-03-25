# FlootySessions

**FlootySessions** is a Julia package that provides **session management** for a multi-agent AI system called "Flooty".

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/yourusername/FlootySessions.jl")
```

## Dependencies

UUIDs, Dates, StructTypes, and various Flooty ecosystem packages (FlootyAbstract, FlootyAgents, etc.)

## Core Purpose

This package manages conversational sessions between users and AI agents, with support for:
- Multiple concurrent chat sessions
- Hierarchical agent structures (parent/child agents)
- Session persistence (save/load)
- Workspace management
- Tool integration

## Session Status Lifecycle

Sessions can be in one of three states:
- `SESSION_ACTIVE` - Currently in use
- `SESSION_PAUSED` - Temporarily suspended
- `SESSION_CLOSED` - Terminated

Status transitions are handled via `pause_session()`, `resume_session()`, and `close_session()`.

## Key Components

### 1. Session (`session.jl`)

A mutable struct representing a chat session containing:
- Unique ID, name, and status (active/paused/closed)
- A root agent and active agent reference
- Workspace folders for file access
- Hierarchical agent tree (root + descendants)
- Active agent tracking for multi-agent conversations
- Tools available to agents
- Metadata and timestamps

### 2. SessionManager (`manager.jl`)

Thread-safe manager for multiple sessions:
- Create, pause, resume, and close sessions
- Track active session
- List all sessions with locking for concurrency
- **Thread-safe** operations using `ReentrantLock`

### 3. SessionData (`persistence.jl`)

Serializable data structure for saving/loading sessions to disk.

## API Overview

### Session Operations
- `Session(name; root_agent, workspace_folders, tools)` - Create new session
- `session_id(s)`, `session_name(s)`, `session_status(s)` - Getters
- `session_agents(s)`, `session_workspace(s)`, `session_tools(s)` - Content access
- `set_active_agent!(s, agent)` - Switch active agent
- `add_agent_to_session!(s, agent)` - Add agent to hierarchy

### Manager Operations
- `SessionManager()` - Create manager
- `create_session!(manager, name; kwargs...)` - Create and register session
- `get_session(manager, id)`, `get_active_session(manager)` - Retrieval
- `set_active_session!(manager, id)` - Set active
- `list_sessions(manager)` - List all
- `close_session!(manager, id)` - Remove session
- `close_all_sessions!(manager)` - Cleanup all

### Persistence
- `SessionData(s)` - Convert to persistable format
- `Session(data, agent_lookup)` - Reconstruct from data

## Ecosystem Context

This is part of a larger "Flooty" framework with related packages:

| Package | Purpose |
|---------|---------|
| **FlootyAgents** | Agent creation and management |
| **FlootyAbstract** | Abstract types and interfaces |
| **FlootyPersistence** | Data persistence layer |
| **FlootyWorkspaces** | File/workspace management |
| **FlootyStreams** | Streaming capabilities |
| **FlootyPermissions** | Access control |

## Example Usage

```julia
using FlootySessions

# Create a session manager
manager = SessionManager()

# Create a new session
session = create_session!(manager, "My Chat"; workspace_folders=["/path/to/files"])

# Set as active
set_active_session!(manager, session.id)

# Later: cleanup
close_session!(manager, session.id)
```

The `examples/tui.jl` demonstrates a full **Terminal User Interface (TUI)** chat application using this package, featuring:
- Multiple session sidebar
- Image attachments
- Model selection
- Message history with persistence

## File Structure

- `src/FlootySessions.jl` - Main module
- `src/session.jl` - Session struct and operations
- `src/manager.jl` - SessionManager implementation
- `src/persistence.jl` - Serialization support

## Summary

In short, this is the "session layer" of a modular AI agent framework, handling the lifecycle and state management of user-AI conversations.
