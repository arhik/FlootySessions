
mutable struct Session <: AbstractSession
    id::UUID
    name::String
    status::SessionStatus
    root_agent::Union{AbstractAgent,Nothing}
    active_agent_id::Union{UUID,Nothing}  # Store ID instead of reference
    workspace_folders::Vector{String}
    tools::Vector{AbstractTool}
    metadata::Dict{String,Any}
    created_at::DateTime
    updated_at::DateTime
    
    # Default constructor for StructTypes
    Session() = new(UUIDs.uuid4(), "", SESSION_ACTIVE, nothing, nothing, String[], AbstractTool[], Dict{String,Any}(), now(), now())
    
    # Full positional constructor
    Session(id::UUID, name::String, status::SessionStatus, 
            root_agent::Union{AbstractAgent,Nothing}, active_agent_id::Union{UUID,Nothing}, 
            workspace_folders::Vector{String}, tools::Vector{<:AbstractTool}, 
            metadata::Dict{String,Any}, created_at::DateTime, updated_at::DateTime) = 
        new(id, name, status, root_agent, active_agent_id, workspace_folders, tools, metadata, created_at, updated_at)
end

# Constructor with defaults
function Session(name::String; 
                 root_agent::Union{AbstractAgent,Nothing}=nothing,
                 workspace_folders::Vector{String}=String[],
                 tools::Vector{<:AbstractTool}=list_default_tools())
    now_time = now()
    active_id = root_agent !== nothing ? root_agent.id : nothing
    
    # Pass session tools to root_agent if agent has no tools
    if root_agent !== nothing && isempty(root_agent.tools) && !isempty(tools)
        root_agent.tools = tools
    end
    
    Session(
        uuid4(),
        name,
        SESSION_ACTIVE,
        root_agent,
        active_id,  # active_agent_id defaults to root_agent.id
        workspace_folders,
        tools,
        Dict{String,Any}(),
        now_time,
        now_time
    )
end

# FlootyAbstract interface implementations
FlootyAbstract.session_id(s::Session) = s.id
FlootyAbstract.session_name(s::Session) = s.name
FlootyAbstract.session_status(s::Session) = s.status

function FlootyAbstract.session_agents(s::Session)
    s.root_agent === nothing ? AbstractAgent[] : AbstractAgent[s.root_agent; descendants(s.root_agent)]
end

FlootyAbstract.session_workspace(s::Session) = s.workspace_folders
FlootyAbstract.session_context(s::Session) = s.metadata
FlootyAbstract.session_created_at(s::Session) = s.created_at
FlootyAbstract.session_updated_at(s::Session) = s.updated_at
FlootyAbstract.session_tools(s::Session) = s.tools

function FlootyAbstract.add_agent_to_session!(s::Session, agent::AbstractAgent)
    if s.root_agent === nothing
        s.root_agent = agent
        s.active_agent_id = agent.id
    else
        add_child!(s.root_agent, agent)
    end
    
    # Pass session tools to agent if agent has no tools
    if isempty(agent.tools) && !isempty(s.tools)
        agent.tools = s.tools
    end
    
    s.updated_at = now()
    s
end

function FlootyAbstract.remove_agent_from_session!(s::Session, agent_id::UUID)
    agents = session_agents(s)
    idx = findfirst(a -> a.id == agent_id, agents)
    if idx === nothing
        return false
    end
    
    agent = agents[idx]
    if s.root_agent == agent
        s.root_agent = nothing
        s.active_agent = nothing
    elseif s.active_agent == agent
        s.active_agent = s.root_agent
    end
    
    s.updated_at = now()
    true
end

function FlootyAbstract.get_agent_from_session(s::Session, agent_id::UUID)
    agents = session_agents(s)
    idx = findfirst(a -> a.id == agent_id, agents)
    idx === nothing ? nothing : agents[idx]
end

function FlootyAbstract.create_subagent_in_session!(s::Session, parent::AbstractAgent, name::String; kwargs...)
    subagent = create_subagent(parent, name, SimpleStack(max_messages=10), ""; kwargs...)
    s.updated_at = now()
    subagent
end

function set_active_agent!(s::Session, agent::AbstractAgent)
    agents = session_agents(s)
    agent in agents || throw(ArgumentError("Agent not in session"))
    s.active_agent_id = agent.id
    s.updated_at = now()
    s
end

function get_active_agent(s::Session)
    s.active_agent_id === nothing && return s.root_agent
    s.root_agent === nothing && return nothing
    
    # If active_agent_id matches root_agent, return root_agent
    if s.active_agent_id == s.root_agent.id
        return s.root_agent
    end
    
    # Otherwise search in descendants
    agents = session_agents(s)
    idx = findfirst(a -> a.id == s.active_agent_id, agents)
    idx === nothing ? s.root_agent : agents[idx]
end

