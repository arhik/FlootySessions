module FlootySessions

using FlootyAbstract
using FlootyAbstract: AbstractSession, AbstractAgent, AbstractTool, SessionStatus, SESSION_ACTIVE, SESSION_PAUSED, SESSION_CLOSED, AbstractPersistable, AbstractPersistenceBackend, save!, load, delete!, list
import FlootyAbstract: get_messages, add_message!
using FlootyAgents: Agent, descendants, add_child!, create_subagent, SimpleStack
using FlootyContextManager
using FlootyStreams: OllamaTool, OllamaFunction
using StructTypes
using UUIDs
using Dates

export Session, SessionManager, SessionData
export session_id, session_name, session_status, session_agents, session_workspace
export session_context, session_created_at, session_updated_at, session_tools
export set_active_agent!
export Tool, ToolParameter, pwd_tool, ls_tool, read_tool, write_tool, shell_tool, diffview_tool, list_default_tools
export get_messages, add_message!

include("session.jl")
include("manager.jl")
include("persistence.jl")
include("tools.jl")

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

function __init__()
    FlootyAbstract.register_tool_handler!("pwd", handle_pwd)
    FlootyAbstract.register_tool_handler!("ls", handle_ls)
    FlootyAbstract.register_tool_handler!("read", handle_read)
    FlootyAbstract.register_tool_handler!("write", handle_write)
    FlootyAbstract.register_tool_handler!("shell", handle_shell)
    FlootyAbstract.register_tool_handler!("diffview", handle_diffview)
end

end # module FlootySessions
