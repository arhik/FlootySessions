
mutable struct Session <: AbstractSession
    id::UUID
    name::String
    status::SessionStatus
    root_agent::Union{AbstractAgent,Nothing}
    active_agent::Union{AbstractAgent,Nothing}
    workspace_folders::Vector{String}
    tools::Vector{<:AbstractTool}
    metadata::Dict{String,Any}
    created_at::DateTime
    updated_at::DateTime
end

# Constructor with defaults
function Session(name::String; 
                 root_agent::Union{AbstractAgent,Nothing}=nothing,
                 workspace_folders::Vector{String}=String[],
                 tools::Vector{<:AbstractTool}=AbstractTool[])
    now_time = now()
    Session(
        uuid4(),
        name,
        SESSION_ACTIVE,
        root_agent,
        root_agent,  # active_agent defaults to root_agent
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
    s.root_agent === nothing ? AbstractAgent[] : collect(descendants(s.root_agent))
end

FlootyAbstract.session_workspace(s::Session) = s.workspace_folders
FlootyAbstract.session_context(s::Session) = s.metadata
FlootyAbstract.session_created_at(s::Session) = s.created_at
FlootyAbstract.session_updated_at(s::Session) = s.updated_at
FlootyAbstract.session_tools(s::Session) = s.tools

function FlootyAbstract.add_agent_to_session!(s::Session, agent::AbstractAgent)
    if s.root_agent === nothing
        s.root_agent = agent
        s.active_agent = agent
    else
        add_child!(s.root_agent, agent)
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
    s.active_agent = agent
    s.updated_at = now()
    s
end

