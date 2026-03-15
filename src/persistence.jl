# ═══════════════════════════════════════════════════════════════════════
# Session Persistence Helpers
# ═══════════════════════════════════════════════════════════════════════

mutable struct SessionData <: AbstractPersistable
    id::UUID
    name::String
    status::Int
    root_agent_id::Union{UUID,Nothing}
    active_agent_id::Union{UUID,Nothing}
    workspace_folders::Vector{String}
    metadata::Dict{String,Any}
    created_at::DateTime
    updated_at::DateTime
    
    SessionData() = new(UUIDs.uuid4(), "", 0, nothing, nothing, String[], Dict{String,Any}(), now(), now())
end

StructTypes.StructType(::Type{SessionData}) = StructTypes.Mutable()

function SessionData(s::Session)
    SessionData(
        s.id,
        s.name,
        Int(s.status),
        s.root_agent === nothing ? nothing : s.root_agent.id,
        s.active_agent === nothing ? nothing : s.active_agent.id,
        s.workspace_folders,
        s.metadata,
        s.created_at,
        s.updated_at
    )
end

function Session(data::SessionData, agent_lookup::Dict{UUID,Agent})
    s = Session()
    s.id = data.id
    s.name = data.name
    s.status = SessionStatus(data.status)
    s.root_agent = get(agent_lookup, data.root_agent_id, nothing)
    s.active_agent = get(agent_lookup, data.active_agent_id, nothing)
    s.workspace_folders = data.workspace_folders
    s.metadata = data.metadata
    s.created_at = data.created_at
    s.updated_at = data.updated_at
    s
end

# persistable_id for FlootyPersistence interface
FlootyAbstract.persistable_id(s::Session) = s.id
FlootyAbstract.persistable_id(s::SessionData) = s.id
