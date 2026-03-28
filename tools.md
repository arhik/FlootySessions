# Dynamic Tools Architecture Options

This document outlines various approaches for implementing dynamic tools in the Flooty ecosystem.

## 1. Runtime Tool Registry

Currently, tools are registered in `__init__()` via `register_tool_handler!`. We can make this dynamic:

```julia
# In FlootyAbstract or FlootyBase
mutable struct ToolRegistry
    handlers::Dict{String, Function}
    definitions::Dict{String, AbstractTool}
    metadata::Dict{String, Dict{String,Any}}  # version, author, permissions, etc.
end

const GLOBAL_REGISTRY = ToolRegistry(Dict(), Dict(), Dict())

function register_tool!(name::String, tool::AbstractTool, handler::Function; metadata=Dict())
    GLOBAL_REGISTRY.handlers[name] = handler
    GLOBAL_REGISTRY.definitions[name] = tool
    GLOBAL_REGISTRY.metadata[name] = metadata
end

function unregister_tool!(name::String)
    delete!(GLOBAL_REGISTRY.handlers, name)
    delete!(GLOBAL_REGISTRY.definitions, name)
    delete!(GLOBAL_REGISTRY.metadata, name)
end

function list_available_tools()::Vector{AbstractTool}
    collect(values(GLOBAL_REGISTRY.definitions))
end
```

## 2. Configuration-Based Tools

Define tools via configuration files that are loaded at runtime:

```julia
# config/tools/custom_tools.json
{
    "tools": [
        {
            "name": "weather_lookup",
            "description": "Get current weather for a location",
            "parameters": [
                {"name": "location", "type": "string", "required": true},
                {"name": "units", "type": "string", "enum": ["celsius", "fahrenheit"], "default": "celsius"}
            ],
            "handler_module": "WeatherTools",
            "handler_function": "get_weather",
            "requires_api_key": true
        }
    ]
}
```

```julia
# Load and register at runtime
function load_tools_from_config(config_path::String)
    config = JSON3.read(read(config_path))
    for tool_def in config.tools
        tool = create_tool_from_config(tool_def)
        handler = get_handler_function(tool_def.handler_module, tool_def.handler_function)
        register_tool!(tool_def.name, tool, handler; metadata=tool_def)
    end
end
```

## 3. Session-Specific Tools

Each session can have its own set of tools:

```julia
mutable struct Session <: AbstractSession
    # ... existing fields ...
    custom_tools::Dict{String, AbstractTool}
    tool_permissions::Dict{String, PermissionSet}
end

function add_session_tool!(session::Session, name::String, tool::AbstractTool, handler::Function)
    session.custom_tools[name] = tool
    register_tool_handler!(name, handler)  # Global handler
    # Or use a session-scoped registry
end

function session_tools(session::Session)
    # Combine default tools + session-specific tools
    vcat(list_default_tools(), collect(values(session.custom_tools)))
end
```

## 4. Tool Factory Pattern

Create tools dynamically based on context:

```julia
abstract type ToolFactory end

struct FileBrowserToolFactory <: ToolFactory
    base_path::String
end

function create_tool(factory::FileBrowserToolFactory)::Tool
    # Create a tool that knows about the specific base_path
    Tool(
        "file_browser",
        "Browse files in $(factory.base_path)",
        [
            ToolParameter("path", "string", "Relative path from $(factory.base_path)"),
            ToolParameter("operation", "string", "Operation: list, read, or search", enum=["list", "read", "search"])
        ]
    )
end

# Usage
factory = FileBrowserToolFactory("/workspace/project")
session_tool = create_tool(factory)
add_session_tool!(session, "project_browser", session_tool, handle_project_browser)
```

## 5. Plugin-Based Tool System

External packages can register tools:

```julia
# In FlootyBase
abstract type ToolPlugin end

function register_plugin(plugin::ToolPlugin)
    for (name, tool, handler) in get_plugin_tools(plugin)
        register_tool!(name, tool, handler; metadata=get_metadata(plugin))
    end
end

# External package example: FlootyGitTools.jl
struct GitToolsPlugin <: ToolPlugin end

function get_plugin_tools(plugin::GitToolsPlugin)
    [
        ("git_status", git_status_tool(), handle_git_status),
        ("git_commit", git_commit_tool(), handle_git_commit),
        ("git_diff", git_diff_tool(), handle_git_diff),
    ]
end

# Register at runtime
using FlootyGitTools
register_plugin(GitToolsPlugin())
```

## 6. Dynamic Tool Parameters

Tools with parameters determined at runtime:

```julia
struct DynamicTool <: AbstractTool
    name::String
    description::String
    parameters_fn::Function  # Returns parameters based on context
end

function tool_parameters(tool::DynamicTool; context=nothing)
    tool.parameters_fn(context)
end

# Usage
db_schema_tool = DynamicTool(
    "query_database",
    "Query the project database",
    (ctx) -> begin
        # Introspect database to get available tables
        tables = get_database_tables(ctx.session)
        [
            ToolParameter("table", "string", "Table to query", enum=tables),
            ToolParameter("columns", "array", "Columns to select"),
            ToolParameter("where_clause", "string", "WHERE clause", required=false)
        ]
    end
)
```

## 7. Composite Tools (Tool Chains)

Combine multiple tools into workflows:

```julia
struct CompositeTool <: AbstractTool
    name::String
    description::String
    steps::Vector{Tuple{String, Function}}  # (tool_name, argument_mapper)
end

function execute_composite_tool(composite::CompositeTool, args::Dict)
    results = Dict()
    for (step_name, arg_mapper) in composite.steps
        step_args = arg_mapper(args, results)
        result = execute_tool(step_name, step_args)
        results[step_name] = result
    end
    ToolResult(results)
end

# Example: "setup_project" tool
setup_project = CompositeTool(
    "setup_project",
    "Clone repo, install deps, and run tests",
    [
        ("git_clone", (args, _) -> Dict("url" => args["repo_url"])),
        ("install_deps", (_, prev) -> Dict("path" => prev["git_clone"].data["path"])),
        ("run_tests", (_, prev) -> Dict("path" => prev["install_deps"].data["path"])),
    ]
)
```

## Implementation Strategy

Recommended implementation in phases:

1. **Phase 1**: Runtime registry + session-specific tools
2. **Phase 2**: Configuration-based tool loading
3. **Phase 3**: Plugin system
4. **Phase 4**: Dynamic parameters and composite tools

## Related Files

- `FlootyBase/src/FlootyBase.jl` - Tool and ToolParameter definitions
- `FlootySessions/src/FlootySessions.jl` - Tool handlers and registration
- `FlootyAbstract/src/abstract/tools.jl` - Abstract tool interfaces
- `FlootyStreams/src/ollama/tools.jl` - Provider-specific tool conversion