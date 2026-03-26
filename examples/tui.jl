# ═══════════════════════════════════════════════════════════════════════
# FlootySessions TUI - Session-based Chat Interface with Persistence
#
# Keys:
#   Ctrl+C or Esc    - Quit (auto-saves sessions)
#   F2               - Toggle session sidebar
#   F3               - New session modal
#   F4               - Delete current session (with confirmation)
#   F5               - Force save all sessions
#   Tab              - Switch focus (sidebar/chat/input)
#   Enter            - Send message (when in input)
#   Up/Down          - Navigate sessions or scroll chat
# ═══════════════════════════════════════════════════════════════════════

using Tachikoma
using FlootySessions
using FlootySessions: Session, SessionManager, set_active_agent!, SessionData
using FlootyAgents
using FlootyAgents: Agent, create_agent, descendants
using FlootyAbstract
using FlootyContextManager: add_message!, get_messages
using FlootyPersistence
using UUIDs
using Dates
using JSON3

@tachikoma_app

# ═══════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════
const PERSISTENCE_DIR = joinpath(homedir(), ".flooty", "sessions")
const SESSIONS_FILE = joinpath(PERSISTENCE_DIR, "sessions.json")

# ═══════════════════════════════════════════════════════════════════════
# Styles
# ═══════════════════════════════════════════════════════════════════════
const GREY_TEXT = Style(fg=Color256(245))
const GREY_DIM = Style(fg=Color256(239))
const GREY_BG = Style(bg=ColorRGB(40, 40, 40))
const USER_BG = Style(bg=ColorRGB(60, 60, 60))
const ASSISTANT_BG = Style(bg=ColorRGB(40, 40, 60))
const TOOL_BG = Style(bg=ColorRGB(40, 80, 40))
const SYSTEM_BG = Style(bg=ColorRGB(80, 60, 40))
const SEPARATOR = Style(fg=Color256(239))
const HIGHLIGHT = Style(fg=ColorRGB(100, 255, 100), bold=true)
const ACTIVE_SESSION = Style(fg=ColorRGB(255, 255, 100), bold=true)
const INACTIVE_SESSION = Style(fg=Color256(245))
const SAVED_STATUS = Style(fg=ColorRGB(100, 255, 100))
const UNSAVED_STATUS = Style(fg=ColorRGB(255, 100, 100))

# ═══════════════════════════════════════════════════════════════════════
# Message Widget
# ═══════════════════════════════════════════════════════════════════════
mutable struct MessageWidget
    message::AbstractMessage
    agent_name::String
    width::Int
    
    function MessageWidget(msg::AbstractMessage, agent_name::String, width::Int)
        new(msg, agent_name, width)
    end
end

function render_widget(buf::Buffer, widget::MessageWidget, x::Int, y::Int, max_y::Int)
    y >= max_y && return 0
    
    msg = widget.message
    msg_role = role(msg)
    msg_content = content(msg) === nothing ? "" : content(msg)
    
    bg_style = if msg_role == "user"
        Style(bg=ColorRGB(60, 60, 60), fg=ColorRGB(255, 255, 255))
    elseif msg_role == "assistant"
        Style(bg=ColorRGB(40, 40, 60), fg=ColorRGB(200, 200, 255))
    elseif msg_role == "tool"
        Style(bg=ColorRGB(40, 80, 40), fg=ColorRGB(200, 255, 200))
    else
        Style(bg=ColorRGB(80, 60, 40), fg=ColorRGB(255, 220, 180))
    end
    
    header = "$(widget.agent_name) [$(msg_role)]"
    set_string!(buf, x + 1, y, header, GREY_DIM)
    
    lines = _wrap_lines(msg_content, widget.width - 4)
    height = 1 + length(lines)
    
    for (i, line) in enumerate(lines)
        line_y = y + i
        line_y >= max_y && break
        
        for cx in (x+1):(x+widget.width-2)
            set_char!(buf, cx, line_y, ' ', bg_style)
        end
        
        set_string!(buf, x + 2, line_y, line, bg_style)
    end
    
    height
end

function _wrap_lines(text::String, width::Int)
    words = split(text, r"\s+", keepempty=false)
    lines = String[]
    current = ""
    
    for word in words
        if isempty(current)
            current = word
        elseif length(current) + 1 + length(word) <= width
            current *= " " * word
        else
            push!(lines, current)
            current = word
        end
    end
    !isempty(current) && push!(lines, current)
    isempty(lines) && push!(lines, "")
    lines
end

# ═══════════════════════════════════════════════════════════════════════
# Persistence Functions
# ═══════════════════════════════════════════════════════════════════════
function save_all_sessions(manager::SessionManager, filepath::String)
    mkpath(dirname(filepath))
    data = Dict(
        "sessions" => [JSON3.write(Dict(s)) for s in values(manager.sessions)],
        "active_session_id" => manager.active_session_id === nothing ? nothing : string(manager.active_session_id)
    )
    open(filepath, "w") do f
        JSON3.write(f, data)
    end
end

function load_all_sessions!(manager::SessionManager, filepath::String)
    isfile(filepath) || return false
    
    data = JSON3.read(read(filepath, String))
    
    # Clear existing sessions
    empty!(manager.sessions)
    
    # Load sessions - for now just create empty sessions
    # Full restoration would require agent lookup
    for s_data in get(data, "sessions", [])
        # Create minimal session
        session = Session("Restored Session")
        manager.sessions[session.id] = session
    end
    
    if haskey(data, "active_session_id") && data["active_session_id"] !== nothing
        manager.active_session_id = UUID(data["active_session_id"])
    end
    
    true
end

# ═══════════════════════════════════════════════════════════════════════
# Modal States
# ═══════════════════════════════════════════════════════════════════════
@enum ModalState MODAL_NONE MODAL_DELETE_CONFIRM MODAL_SESSION_SWITCHER

# ═══════════════════════════════════════════════════════════════════════
# TUI Model
# ═══════════════════════════════════════════════════════════════════════
@kwdef mutable struct TuiModel <: Model
    quit::Bool = false
    tick::Int = 0
    manager::SessionManager = SessionManager()
    current_session::Union{Session,Nothing} = nothing
    input::TextInput = TextInput(text="", focused=true, tick=0)
    task_queue::TaskQueue = TaskQueue()
    is_streaming::Bool = false
    show_sidebar::Bool = true
    sidebar_focused::Bool = false
    scroll_offset::Int = 0
    session_list::SelectableList = SelectableList(String[]; focused=false)
    
    # Modal state
    modal::ModalState = MODAL_NONE
    modal_input::TextInput = TextInput(text="", focused=true, tick=0)
    modal_selected::Symbol = :cancel
    modal_message::String = ""
    
    # Persistence
    persistence_backend::JSONBackend = JSONBackend(PERSISTENCE_DIR)
    last_save::DateTime = now()
    auto_save_interval::Int = 30  # seconds
end

should_quit(m::TuiModel) = m.quit
task_queue(m::TuiModel) = m.task_queue

# ═══════════════════════════════════════════════════════════════════════
# Session Management
# ═══════════════════════════════════════════════════════════════════════
function _create_default_session!(m::TuiModel, name::String="")
    # Auto-generate name if not provided
    if isempty(name)
        session_count = length(list_sessions(m.manager))
        name = "Session $(session_count + 1)"
    end
    
    agent = create_agent("Assistant", :ollama)
    session = create_session!(m.manager, name; root_agent=agent)
    set_active_session!(m.manager, session.id)
    m.current_session = session
    _update_session_list!(m)
    _auto_save!(m)
    session
end

function _update_session_list!(m::TuiModel)
    sessions = list_sessions(m.manager)
    active_id = m.manager.active_session_id
    
    items = map(sessions) do s
        prefix = s.id == active_id ? "▸ " : "  "
        status = s.status == SESSION_ACTIVE ? "●" : "○"
        "$prefix$status $(s.name)"
    end
    
    m.session_list = SelectableList(items; focused=m.sidebar_focused, tick=m.tick)
    nothing
end

function _switch_to_session!(m::TuiModel, idx::Int)
    sessions = list_sessions(m.manager)
    (idx < 1 || idx > length(sessions)) && return false
    
    session = sessions[idx]
    set_active_session!(m.manager, session.id)
    m.current_session = session
    _update_session_list!(m)
    m.scroll_offset = 0
    _auto_save!(m)
    true
end

function _delete_current_session!(m::TuiModel)
    m.current_session === nothing && return false
    session_id = m.current_session.id
    
    close_session!(m.manager, session_id)
    m.current_session = get_active_session(m.manager)
    _update_session_list!(m)
    _auto_save!(m)
    true
end

function _auto_save!(m::TuiModel)
    for session in values(m.manager.sessions)
        save!(m.persistence_backend, session)
    end
    m.last_save = now()
end

function _needs_auto_save(m::TuiModel)::Bool
    seconds_since_save = Dates.value(now() - m.last_save) / 1000
    seconds_since_save >= m.auto_save_interval
end

# ═══════════════════════════════════════════════════════════════════════
# Event Handling
# ═══════════════════════════════════════════════════════════════════════
function update!(m::TuiModel, evt::Event)
    if evt isa KeyEvent
        _handle_key!(m, evt)
    elseif evt isa MouseEvent
        _handle_mouse!(m, evt)
    end
    
    # Auto-save check
    if _needs_auto_save(m)
        _auto_save!(m)
    end
end

function _handle_key!(m::TuiModel, evt::KeyEvent)
    # Modal handling takes precedence
    if m.modal != MODAL_NONE
        _handle_modal_key!(m, evt)
        return
    end
    
    # Global shortcuts
    if (evt.key == :char && evt.char == '\x03') || evt.key == :escape
        _auto_save!(m)  # Save before quit
        m.quit = true
        return
    end
    
    if evt.key == :f2
        m.show_sidebar = !m.show_sidebar
        return
    end
    
    if evt.key == :f3
        _create_default_session!(m)  # Create immediately with auto-name
        return
    end
    
    if evt.key == :f4
        _open_delete_modal!(m)
        return
    end
    
    if evt.key == :f5
        _auto_save!(m)
        return
    end
    
    # Tab switches focus
    if evt.key == :tab
        if m.sidebar_focused
            m.sidebar_focused = false
            m.session_list.focused = false
        else
            m.sidebar_focused = true
            m.session_list.focused = true
        end
        return
    end
    
    # Sidebar navigation
    if m.sidebar_focused && m.show_sidebar
        handled = handle_key!(m.session_list, evt)
        if handled
            _switch_to_session!(m, m.session_list.selected)
        end
        return
    end
    
    # Chat scroll
    if evt.key == :pageup
        m.scroll_offset = max(0, m.scroll_offset - 5)
        return
    elseif evt.key == :pagedown
        m.scroll_offset += 5
        return
    end
    
    # Input handling
    if !m.sidebar_focused
        handled = handle_key!(m.input, evt)
        if !handled && (String(m.input.buffer) |> strip |> !isempty) &&
           (evt.key == :enter || (evt.key == :char && evt.char == '\n'))
            _send_message!(m)
        end
    end
end

function _handle_modal_key!(m::TuiModel, evt::KeyEvent)
    if m.modal == MODAL_DELETE_CONFIRM
        if evt.key == :left
            m.modal_selected = :cancel
        elseif evt.key == :right
            m.modal_selected = :confirm
        elseif evt.key == :enter
            if m.modal_selected == :confirm
                _delete_current_session!(m)
            end
            m.modal = MODAL_NONE
        elseif evt.key == :escape
            m.modal = MODAL_NONE
        end
        
    elseif m.modal == MODAL_SESSION_SWITCHER
        handled = handle_key!(m.session_list, evt)
        if handled
            _switch_to_session!(m, m.session_list.selected)
        elseif evt.key == :enter
            m.modal = MODAL_NONE
        elseif evt.key == :escape
            m.modal = MODAL_NONE
        end
    end
end

function _handle_mouse!(m::TuiModel, evt::MouseEvent)
    # TODO: Implement mouse support
end

function _open_delete_modal!(m::TuiModel)
    m.current_session === nothing && return
    m.modal = MODAL_DELETE_CONFIRM
    m.modal_selected = :cancel
    m.modal_message = "Delete session '$(m.current_session.name)'?"
end

function _generate_session_name(agent::Agent, first_message::String)::String
    # Ask agent to suggest a name based on the query
    naming_prompt = """Suggest a concise session name (2-4 words) for a conversation that starts with this query: \"$first_message\"

Reply with ONLY the name, no quotes or explanation. Keep it under 40 characters."""
    
    try
        response = FlootyAbstract.chat(agent, naming_prompt; stream=false, auto_tools=false)
        name = strip(FlootyAbstract.content(response))
        
        # Clean up the name
        name = replace(name, r"^[[\\\"']+" => "")  # Remove leading quotes
        name = replace(name, r"[[\\\"']+$" => "")  # Remove trailing quotes
        name = strip(name)
        
        # Fallback if empty or too long
        isempty(name) && return "New Session"
        length(name) > 40 && return name[1:40] * "..."
        
        return name
    catch
        # Fallback to truncated query
        words = split(first_message)
        name = join(words[1:min(4, length(words))], " ")
        return length(name) > 40 ? name[1:40] * "..." : name
    end
end

function _send_message!(m::TuiModel)
    m.current_session === nothing && return
    m.current_session.root_agent === nothing && return
    
    text = String(strip(String(m.input.buffer)))
    isempty(text) && return
    
    # Check if this is first message (for auto-naming)
    agent = m.current_session.active_agent !== nothing ? 
            m.current_session.active_agent : 
            m.current_session.root_agent
    
    is_first_message = isempty(get_messages(FlootyAbstract.context(agent)))
    
    empty!(m.input.buffer)
    m.input.cursor = 0
    m.is_streaming = true
    
    result_channel = Channel{Any}(1)
    @async begin
        try
            result = FlootyAbstract.chat(agent, text; stream=false, auto_tools=true)
            put!(result_channel, result)
        catch e
            put!(result_channel, e)
        end
    end
    
    @async begin
        result = take!(result_channel)
        m.is_streaming = false
        if result isa Exception
            prov = FlootyAbstract.provider(agent)
            add_message!(FlootyAbstract.context(agent), 
                create_message(prov, "system", "⚠️ Error: $(sprint(showerror, result))"))
        elseif result isa FlootyAbstract.AbstractFlootyError
            prov = FlootyAbstract.provider(agent)
            add_message!(FlootyAbstract.context(agent), 
                create_message(prov, "system", "⚠️ Chat error: $(result.message)"))
        end
        
        # Auto-rename session after first message exchange
        if is_first_message && m.current_session !== nothing
            new_name = _generate_session_name(agent, text)
            if !isempty(new_name) && m.current_session.name != new_name
                m.current_session.name = new_name
                m.current_session.updated_at = now()
                _update_session_list!(m)
            end
        end
        
        # Trigger auto-save after message
        m.last_save = DateTime(0)  # Force save on next check
    end
end

# ═══════════════════════════════════════════════════════════════════════
# Rendering
# ═══════════════════════════════════════════════════════════════════════
function view(m::TuiModel, f::Frame)
    m.tick += 1
    buf = f.buffer
    
    _update_session_list!(m)
    
    # Layout
    sidebar_width = m.show_sidebar ? 35 : 0
    chat_width = f.area.width - sidebar_width
    
    sidebar_area = Rect(f.area.x, f.area.y, sidebar_width, f.area.height - 3)
    chat_area = Rect(f.area.x + sidebar_width, f.area.y, chat_width, f.area.height - 3)
    input_area = Rect(f.area.x + sidebar_width, f.area.y + f.area.height - 3, chat_width, 3)
    
    # Draw separator
    if m.show_sidebar
        sep_x = f.area.x + sidebar_width
        for y in f.area.y:(f.area.y + f.area.height - 4)
            set_char!(buf, sep_x, y, '┃', SEPARATOR)
        end
    end
    
    # Render sidebar
    if m.show_sidebar
        _render_sidebar!(m, buf, sidebar_area)
    end
    
    # Render chat
    _render_chat!(m, buf, chat_area)
    
    # Render input
    _render_input!(m, buf, input_area)
    
    # Status bar
    status = _build_status(m)
    set_string!(buf, f.area.x, f.area.y + f.area.height - 1, status, GREY_DIM)
    
    # Render modal if active
    if m.modal != MODAL_NONE
        _render_modal!(m, buf, f.area)
    end
end

function _build_status(m::TuiModel)::String
    parts = String[]
    
    if m.current_session !== nothing
        push!(parts, "Session: $(m.current_session.name)")
        agent_count = length(session_agents(m.current_session))
        push!(parts, "Agents: $agent_count")
    else
        push!(parts, "No session")
    end
    
    # Save status
    seconds_since_save = Dates.value(now() - m.last_save) / 1000
    if seconds_since_save < 5
        push!(parts, "✓ saved")
    else
        push!(parts, "○ unsaved")
    end
    
    m.is_streaming && push!(parts, "⏳ streaming")
    
    push!(parts, "F2:sidebar F3:new F4:delete F5:save Ctrl+C:quit")
    
    join(parts, " | ")
end

function _render_sidebar!(m::TuiModel, buf::Buffer, area::Rect)
    # Title
    title = " Sessions "
    title_x = center(area, length(title), 1).x
    set_string!(buf, title_x, area.y, title, HIGHLIGHT)
    
    # Session list
    list_area = Rect(area.x, area.y + 2, area.width, area.height - 4)
    m.session_list.tick = m.tick
    m.session_list.focused = m.sidebar_focused
    render(m.session_list, list_area, buf)
    
    # Help text at bottom
    help_y = bottom(area) - 2
    set_string!(buf, area.x + 1, help_y, "F3: New", GREY_DIM)
    set_string!(buf, area.x + 1, help_y + 1, "F4: Delete", GREY_DIM)
end

function _render_chat!(m::TuiModel, buf::Buffer, area::Rect)
    m.current_session === nothing && return
    m.current_session.root_agent === nothing && return
    
    agent = m.current_session.root_agent
    messages = get_messages(FlootyAbstract.context(agent))
    
    rendered_height = 0
    for msg in messages
        widget = MessageWidget(msg, agent.name, area.width)
        y = area.y - m.scroll_offset + rendered_height
        
        if y >= area.y && y < bottom(area) - 1
            h = render_widget(buf, widget, area.x, y, bottom(area) - 1)
            rendered_height += h + 1
        end
    end
end

function _render_input!(m::TuiModel, buf::Buffer, area::Rect)
    for y in area.y:bottom(area)
        for x in area.x:(area.x + area.width - 1)
            set_char!(buf, x, y, ' ', GREY_BG)
        end
    end
    
    prompt = m.current_session !== nothing ? " > " : " [No session] "
    set_string!(buf, area.x + 1, area.y + 1, prompt, GREY_TEXT)
    
    if m.current_session !== nothing
        inner_area = Rect(area.x + length(prompt) + 1, area.y + 1, area.width - length(prompt) - 2, 1)
        m.input.focused = !m.sidebar_focused && m.modal == MODAL_NONE
        m.input.tick = m.tick
        render(m.input, inner_area, buf)
    end
end

function _render_modal!(m::TuiModel, buf::Buffer, area::Rect)
    if m.modal == MODAL_DELETE_CONFIRM
        _render_delete_modal!(m, buf, area)
    end
end

function _render_delete_modal!(m::TuiModel, buf::Buffer, area::Rect)
    modal = Modal(
        title="Confirm Delete",
        message=m.modal_message,
        confirm_label="Delete",
        cancel_label="Cancel",
        selected=m.modal_selected,
        confirm_style=tstyle(:error, bold=true),
        tick=m.tick
    )
    
    render(modal, area, buf)
end

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════
function flooty_sessions_tui()
    model = TuiModel()
    
    # Try to load existing sessions
    try
        # Load from persistence directory
        sessions = list(model.persistence_backend, Session)
        for session in sessions
            model.manager.sessions[session.id] = session
        end
        if !isempty(sessions)
            model.current_session = first(sessions)
            set_active_session!(model.manager, model.current_session.id)
        end
    catch e
        @info "No existing sessions found or error loading: $e"
    end
    
    app(model; fps=30)
end

# Run: flooty_sessions_tui()
