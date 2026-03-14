module FlootySessions

using FlootyAbstract
using FlootyAbstract: AbstractSession, AbstractAgent, AbstractTool, SessionStatus, SESSION_ACTIVE, SESSION_PAUSED, SESSION_CLOSED
using FlootyAgents: Agent, descendants, add_child!, create_subagent, SimpleStack
using UUIDs
using Dates

export Session, SessionManager
export session_id, session_name, session_status, session_agents, session_workspace
export session_context, session_created_at, session_updated_at, session_tools
export set_active_agent!

include("session.jl")
include("manager.jl")

end # module FlootySessions
