module FlootySessions

using FlootyAbstract
using FlootyAbstract: AbstractSession, AbstractAgent, SessionStatus, SESSION_ACTIVE, SESSION_PAUSED, SESSION_CLOSED
using FlootyAgents: Agent, descendants, add_child!, create_subagent, SimpleStack
using UUIDs
using Dates

export Session, SessionManager
export session_id, session_name, session_status, session_agents, session_workspace
export session_context, session_created_at, session_updated_at

include("session.jl")
include("manager.jl")

end # module FlootySessions
