# Provider-agnostic Tool Definitions
# These are pure data structures that can be converted to provider-specific formats

mutable struct ToolParameter
    name::String
    param_type::String
    description::String
    required::Bool
    default::Union{Nothing,Any}
    
    ToolParameter(name, type, desc; required=true, default=nothing) = 
        new(name, type, desc, required, default)
end

# Tool - A concrete AbstractTool implementation for FlootySessions
mutable struct Tool <: FlootyAbstract.AbstractTool
    name::String
    description::String
    parameters::Vector{ToolParameter}
    
    Tool(name, desc, params=ToolParameter[]) = new(name, desc, params)
end

# Common tool builders
function pwd_tool()::Tool
    Tool("pwd", "Get the current working directory path", ToolParameter[])
end

function read_tool()::Tool
    params = [
        ToolParameter("path", "string", "Path to the file to read", required=true),
        ToolParameter("start_line", "integer", "Starting line number (1-based)", required=false),
        ToolParameter("end_line", "integer", "Ending line number (1-based, inclusive)", required=false)
    ]
    Tool("read", "Read file contents. First line of file is line 1 (1-based indexing)", params)
end

function write_tool()::Tool
    params = [
        ToolParameter("path", "string", "Path to the file", required=true),
        ToolParameter("content", "string", "Content to write", required=true),
        ToolParameter("start_line", "integer", "First line to replace (1-based)", required=false),
        ToolParameter("end_line", "integer", "Last line to replace (1-based)", required=false)
    ]
    Tool("write", "Write file or replace line ranges", params)
end

function ls_tool()::Tool
    params = [
        ToolParameter("path", "string", "Path to the directory to list", required=false, default=".")
    ]
    Tool("ls", "List files and directories", params)
end

function shell_tool()::Tool
    params = [
        ToolParameter("command", "string", "Shell command to execute", required=true),
        ToolParameter("args", "array", "Command arguments", required=false)
    ]
    Tool("shell", "Execute shell commands (ls, pwd, cd, grep, cat, etc.)", params)
end

function diffview_tool()::Tool
    params = [
        ToolParameter("old_path", "string", "Path to old/original file", required=true),
        ToolParameter("new_path", "string", "Path to new/modified file", required=true)
    ]
    Tool("diffview", "Show diff between two files", params)
end

# Default tools for sessions
function list_default_tools()
    [pwd_tool(), ls_tool(), read_tool(), write_tool(), shell_tool(), diffview_tool()]
end

function list_default_tools(session::Session)
    tools = FlootyAbstract.session_tools(session)
    isempty(tools) ? list_default_tools() : tools
end

# Implement FlootyAbstract interface for Tool
FlootyAbstract.tool_name(tool::Tool) = tool.name
FlootyAbstract.tool_description(tool::Tool) = tool.description
FlootyAbstract.tool_parameters(tool::Tool) = tool.parameters

