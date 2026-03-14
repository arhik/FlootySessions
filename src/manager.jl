mutable struct SessionManager <: AbstractSessionManager
    sessions::Dict{UUID,Session}
    active_session_id::Union{UUID,Nothing}
    lock::ReentrantLock
    
    function SessionManager()
        new(Dict{UUID,Session}(), nothing, ReentrantLock())
    end
end

# Session lifecycle functions
function FlootyAbstract.create_session(name::String; kwargs...)
    Session(name; kwargs...)
end

function FlootyAbstract.pause_session(s::Session)
    s.status = SESSION_PAUSED
    s.updated_at = now()
    s
end

function FlootyAbstract.resume_session(s::Session)
    s.status = SESSION_ACTIVE
    s.updated_at = now()
    s
end

function FlootyAbstract.close_session(s::Session)
    s.status = SESSION_CLOSED
    s.updated_at = now()
    s
end

# SessionManager operations
function FlootyAbstract.create_session!(manager::SessionManager, name::String; kwargs...)
    session = create_session(name; kwargs...)
    lock(manager.lock) do
        manager.sessions[session.id] = session
    end
    session
end

function FlootyAbstract.get_session(manager::SessionManager, session_id::UUID)
    lock(manager.lock) do
        get(manager.sessions, session_id, nothing)
    end
end

function FlootyAbstract.get_active_session(manager::SessionManager)
    lock(manager.lock) do
        manager.active_session_id === nothing ? nothing : get(manager.sessions, manager.active_session_id, nothing)
    end
end

function FlootyAbstract.set_active_session!(manager::SessionManager, session_id::UUID)
    lock(manager.lock) do
        if haskey(manager.sessions, session_id)
            manager.active_session_id = session_id
            true
        else
            false
        end
    end
end

function FlootyAbstract.list_sessions(manager::SessionManager)
    lock(manager.lock) do
        collect(values(manager.sessions))
    end
end

function FlootyAbstract.close_session!(manager::SessionManager, session_id::UUID)
    lock(manager.lock) do
        session = get(manager.sessions, session_id, nothing)
        if session !== nothing
            close_session(session)
            delete!(manager.sessions, session_id)
            if manager.active_session_id == session_id
                manager.active_session_id = nothing
            end
            true
        else
            false
        end
    end
end

function FlootyAbstract.close_all_sessions!(manager::SessionManager)
    lock(manager.lock) do
        for session in values(manager.sessions)
            close_session(session)
        end
        empty!(manager.sessions)
        manager.active_session_id = nothing
    end
end

