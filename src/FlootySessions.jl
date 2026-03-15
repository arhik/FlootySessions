module FlootySessions

using FlootyAbstract
using FlootyAbstract: AbstractSession, AbstractAgent, AbstractTool, SessionStatus, SESSION_ACTIVE, SESSION_PAUSED, SESSION_CLOSED, AbstractPersistable, AbstractPersistenceBackend, save!, load, delete!, list
using FlootyAgents: Agent, descendants, add_child!, create_subagent, SimpleStack
using StructTypes
using UUIDs
using Dates

export Session, SessionManager, SessionData
export session_id, session_name, session_status, session_agents, session_workspace
export session_context, session_created_at, session_updated_at, session_tools
export set_active_agent!

include("session.jl")
include("manager.jl")
include("persistence.jl")

# Session - Mutable struct with abstract type fields
# AbstractAgent and AbstractTool are handled via AbstractType in FlootyAgents
StructTypes.StructType(::Type{Session}) = StructTypes.Mutable()

# SessionStatus - serialize as Int via custom lower/construct
StructTypes.StructType(::Type{SessionStatus}) = StructTypes.CustomStruct()
StructTypes.lower(x::SessionStatus) = Int(x)
StructTypes.construct(::Type{SessionStatus}, x::Int) = SessionStatus(x)

end # module FlootySessions
