# ═══════════════════════════════════════════════════════════════════════
# FlootySessions TUI - Session-based Chat Interface with Persistence
#
# Keys:
#   Ctrl+C or Esc    - Quit (auto-saves sessions)
#   F2               - Toggle session sidebar
#   F3               - New session modal
#   F4               - Delete current session (with confirmation)
#   F5               - Force save all sessions
#   F6               - Select model for current session
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
    
    # Padding constants
    padding_top = 1
    padding_bottom = 1
    padding_left = 2
    padding_right = 2
    
    # Determine base style
    base_style = if msg_role == "user"
        Style(bg=ColorRGB(60, 60, 60), fg=ColorRGB(255, 255, 255))
    elseif msg_role == "assistant"
        Style(bg=ColorRGB(40, 40, 60), fg=ColorRGB(200, 200, 255))
    elseif msg_role == "tool"
        # Tool messages: start as assistant (purple), change to green/red based on result
        # Check if output contains error
        if occursin("\nError:", msg_content) || startswith(msg_content, "Error:")
            Style(bg=ColorRGB(80, 40, 40), fg=ColorRGB(255, 200, 200))  # Red for error
        else
            Style(bg=ColorRGB(40, 80, 40), fg=ColorRGB(200, 255, 200))  # Green for success
        end
    else
        Style(bg=ColorRGB(80, 60, 40), fg=ColorRGB(255, 220, 180))
    end
    
    # Calculate dimensions
    content_width = widget.width - padding_left - padding_right
    # Preserve whitespace for tool messages (ls -l, etc.)
    preserve_ws = msg_role == "tool"
    lines = _wrap_lines(msg_content, content_width; preserve_whitespace=preserve_ws)
    content_height = length(lines)
    
    # Calculate total height (header only for tool/system messages)
    # Tool messages have header + separator line
    header_height = if msg_role == "tool"
        2  # header line + separator line
    elseif msg_role == "system"
        1
    else
        0
    end
    total_height = padding_top + header_height + content_height + padding_bottom
    
    # Fill entire widget background first (including all padding)
    for row_y in y:(y + total_height - 1)
        row_y >= max_y && break
        for cx in x:(x + widget.width - 1)
            set_char!(buf, cx, row_y, ' ', base_style)
        end
    end
    
    # Header line (after top padding) - only show for tool/system messages
    if msg_role == "tool"
        # Parse tool name and args from first line of content
        # Format: $ tool_name args\noutput
        header = "\$ tool"
        trimmed_content = strip(msg_content)
        if !isempty(trimmed_content) && startswith(trimmed_content, "\$")
            # Extract tool call from first line
            first_newline = findfirst('\n', trimmed_content)
            if first_newline !== nothing
                header = trimmed_content[1:first_newline-1]
            else
                header = trimmed_content
            end
        end
        header_y = y + padding_top
        header_y >= max_y && return total_height
        # Use same style as content for seamless background
        set_string!(buf, x + padding_left, header_y, header, base_style)
        
        # Add separator line after tool header
        sep_y = header_y + 1
        sep_y >= max_y && return total_height
        sep_width = widget.width - padding_left - padding_right
        separator = repeat("─", sep_width)
        set_string!(buf, x + padding_left, sep_y, separator, base_style)
        content_start_y = sep_y + 1
    elseif msg_role == "system"
        header = "[system]"
        header_y = y + padding_top
        header_y >= max_y && return total_height
        set_string!(buf, x + padding_left, header_y, header, GREY_DIM)
        content_start_y = header_y + 1
    else
        content_start_y = y + padding_top
    end
    
    # Content lines (after header if present)
    # For tool messages, skip the first line (it's the header we already displayed)
    start_idx = msg_role == "tool" && length(lines) > 0 ? 2 : 1
    for i in start_idx:length(lines)
        line = lines[i]
        line_y = content_start_y + (i - start_idx)
        line_y >= max_y - padding_bottom && break
        set_string!(buf, x + padding_left, line_y, line, base_style)
    end
    
    # Return total height
    return total_height
end

function _wrap_lines(text::String, width::Int; preserve_whitespace::Bool=false)
    if preserve_whitespace
        # For preformatted text (like ls -l), preserve all whitespace
        # Split into lines first, then wrap each line if needed
        input_lines = split(text, '\n', keepempty=true)
        lines = String[]
        for line in input_lines
            if length(line) <= width
                push!(lines, line)
            else
                # Hard wrap long lines
                for i in 1:width:length(line)
                    end_idx = min(i + width - 1, length(line))
                    push!(lines, line[i:end_idx])
                end
            end
        end
        isempty(lines) && push!(lines, "")
        return lines
    end
    
    # Normal word wrapping for regular text
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
    # Use StructTypes to serialize sessions directly
    data = Dict(
        "sessions" => [JSON3.write(s) for s in values(manager.sessions)],
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
    
    # Load sessions using proper StructTypes deserialization
    for s_data in get(data, "sessions", [])
        # Use JSON3.read with Session type for proper deserialization
        session = JSON3.read(s_data, Session)
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
@enum ModalState MODAL_NONE MODAL_DELETE_CONFIRM MODAL_SESSION_SWITCHER MODAL_MODEL_SELECT

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
    
    # Model selection
    available_models::Vector{String} = [
        "nemotron-3-nano:30b-cloud",
        "qwen3:4b",
        "devstral-small-2:24b-cloud",
        "llama3.2:3b",
        "mistral:7b"
    ]
    model_list::SelectableList = SelectableList(String[]; focused=false)
    
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
    # Save current session before creating new one
    if m.current_session !== nothing
        _auto_save!(m)
    end
    
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
    
    # Preserve current selection if possible
    old_selected = m.session_list.selected
    
    items = map(sessions) do s
        is_active = s.id == active_id
        prefix = is_active ? "▸ " : "  "
        status = s.status == SESSION_ACTIVE ? "●" : "○"
        # Use different style for active session
        style = is_active ? ACTIVE_SESSION : INACTIVE_SESSION
        ListItem("$prefix$status $(s.name)", style)
    end
    
    # Create new list but preserve selection
    m.session_list = SelectableList(items; focused=m.sidebar_focused, tick=m.tick, selected=old_selected)
    nothing
end

function _switch_to_session!(m::TuiModel, idx::Int)
    sessions = list_sessions(m.manager)
    (idx < 1 || idx > length(sessions)) && return false
    
    # Save current session before switching
    if m.current_session !== nothing
        _auto_save!(m)
    end
    
    session = sessions[idx]
    
    # Ensure session has a valid agent
    if session.root_agent === nothing
        # Create a new agent if none exists
        agent = create_agent("Assistant", :ollama)
        session.root_agent = agent
        session.active_agent = agent
    end
    
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
    # Save individual session files
    for session in values(m.manager.sessions)
        save!(m.persistence_backend, session)
    end
    # Save sessions.json with session list and active session
    save_all_sessions(m.manager, SESSIONS_FILE)
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
    
    if evt.key == :f6
        _open_model_select_modal!(m)
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
    elseif evt.key == :end_key
        # Scroll to bottom (Ctrl+End or just End)
        m.scroll_offset = -1  # Will be recalculated in _render_chat!
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
        
    elseif m.modal == MODAL_MODEL_SELECT
        handled = handle_key!(m.model_list, evt)
        if handled
            # Model selection changed
        elseif evt.key == :enter
            _select_model!(m)
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

function _open_model_select_modal!(m::TuiModel)
    m.current_session === nothing && return
    m.modal = MODAL_MODEL_SELECT
    # Initialize model list with available models
    m.model_list = SelectableList(m.available_models; focused=true, tick=m.tick)
    # Select current model if present
    if m.current_session !== nothing && m.current_session.root_agent !== nothing
        current_model = m.current_session.root_agent.model
        idx = findfirst(==(current_model), m.available_models)
        if idx !== nothing
            m.model_list.selected = idx
        end
    end
end

function _select_model!(m::TuiModel)
    m.current_session === nothing && return
    m.current_session.root_agent === nothing && return
    
    selected_idx = m.model_list.selected
    selected_idx < 1 && return
    selected_idx > length(m.available_models) && return
    
    new_model = m.available_models[selected_idx]
    m.current_session.root_agent.model = new_model
    
    # Also update active_agent if it's a different agent in the tree
    active_agent = FlootySessions.get_active_agent(m.current_session)
    if active_agent !== nothing && active_agent !== m.current_session.root_agent
        active_agent.model = new_model
    end
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
    
    # Get the agent to use
    agent = FlootySessions.get_active_agent(m.current_session)
    agent === nothing && return
    
    is_first_message = isempty(get_messages(agent.context))
    
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
            add_message!(agent.context, 
                create_message(prov, "system", "⚠️ Error: $(sprint(showerror, result))"))
        elseif result isa FlootyAbstract.AbstractFlootyError
            prov = FlootyAbstract.provider(agent)
            add_message!(agent.context, 
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
    status_height = 1
    input_height = 3
    
    sidebar_area = Rect(f.area.x, f.area.y, sidebar_width, f.area.height - status_height - input_height)
    chat_area = Rect(f.area.x + sidebar_width, f.area.y, chat_width, f.area.height - status_height - input_height)
    input_area = Rect(f.area.x + sidebar_width, f.area.y + f.area.height - status_height - input_height, chat_width, input_height)
    
    # Draw separator
    if m.show_sidebar
        sep_x = f.area.x + sidebar_width
        sep_end_y = f.area.y + f.area.height - status_height - input_height - 1
        for y in f.area.y:sep_end_y
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
    
    push!(parts, "F2:sidebar F3:new F4:delete F5:save F6:model End:bottom Ctrl+C:quit")
    
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
    messages = get_messages(agent.context)
    
    # Calculate scrollbar area (right side of chat)
    scrollbar_width = 1
    content_width = area.width - scrollbar_width - 2  # -2 for padding
    content_area = Rect(area.x + 1, area.y, content_width, area.height)
    scrollbar_area = Rect(right(content_area), area.y, scrollbar_width, area.height)
    
    # Calculate total content height
    total_height = 0
    for msg in messages
        widget = MessageWidget(msg, agent.name, content_width)
        total_height += _calculate_widget_height(widget) + 1  # +1 for spacing
    end
    
    # Auto-scroll to bottom if at end
    if m.scroll_offset < 0 || m.scroll_offset + area.height >= total_height
        m.scroll_offset = max(0, total_height - area.height)
    end
    
    # Render messages with padding
    rendered_height = 0
    for msg in messages
        widget = MessageWidget(msg, agent.name, content_width)
        y = content_area.y - m.scroll_offset + rendered_height
        
        if y + _calculate_widget_height(widget) >= content_area.y && y < bottom(content_area)
            h = render_widget(buf, widget, content_area.x, y, bottom(content_area))
            rendered_height += h + 1
        else
            rendered_height += _calculate_widget_height(widget) + 1
        end
    end
    
    # Render scrollbar
    _render_scrollbar!(buf, scrollbar_area, m.scroll_offset, total_height, area.height)
end

function _calculate_widget_height(widget::MessageWidget)::Int
    msg = widget.message
    content_str = content(msg) === nothing ? "" : content(msg)
    lines = _wrap_lines(content_str, widget.width - 4)
    return 1 + length(lines) + 2  # header + content lines + padding
end

function _render_scrollbar!(buf::Buffer, area::Rect, scroll_offset::Int, total_height::Int, viewport_height::Int)
    total_height <= viewport_height && return  # No scrollbar needed
    
    scrollbar_style = Style(fg=Color256(245), bg=Color256(240))
    thumb_style = Style(fg=Color256(255), bg=Color256(250))
    
    # Draw scrollbar track
    for y in area.y:bottom(area)
        set_char!(buf, area.x, y, '│', scrollbar_style)
    end
    
    # Calculate thumb position and size
    thumb_ratio = viewport_height / total_height
    thumb_size = max(1, round(Int, viewport_height * thumb_ratio))
    max_scroll = total_height - viewport_height
    scroll_ratio = scroll_offset / max_scroll
    thumb_pos = area.y + round(Int, (area.height - thumb_size) * scroll_ratio)
    thumb_pos = clamp(thumb_pos, area.y, bottom(area) - thumb_size + 1)
    
    # Draw thumb
    for y in thumb_pos:min(thumb_pos + thumb_size - 1, bottom(area))
        set_char!(buf, area.x, y, '█', thumb_style)
    end
end

function _render_input!(m::TuiModel, buf::Buffer, area::Rect)
    # Match chat area constraints (same as _render_chat!)
    scrollbar_width = 1
    left_padding = 1
    right_padding = 1
    
    # Content area matches message content area
    content_width = area.width - scrollbar_width - left_padding - right_padding
    content_x = area.x + left_padding
    
    # Padding within the content area (match message padding)
    padding_top = 1
    padding_bottom = 1
    padding_left = 2
    padding_right = 2
    
    # User message style for input (matches user messages)
    input_style = Style(bg=ColorRGB(60, 60, 60), fg=ColorRGB(255, 255, 255))
    cursor_style = Style(bg=ColorRGB(100, 100, 100), fg=ColorRGB(255, 255, 255))
    
    # Fill background only within content area (not in sidebar or under scrollbar)
    content_area_y_start = area.y
    content_area_y_end = area.y + area.height - 1
    content_area_x_start = content_x
    content_area_x_end = content_x + content_width - 1
    
    for y in content_area_y_start:content_area_y_end
        for x in content_area_x_start:content_area_x_end
            set_char!(buf, x, y, ' ', input_style)
        end
    end
    
    if m.current_session === nothing
        # Show "No session" message centered in content area
        msg = " [No session] "
        msg_x = content_x + div(content_width - length(msg), 2)
        msg_y = area.y + div(area.height, 2)
        set_string!(buf, msg_x, msg_y, msg, GREY_TEXT)
        return
    end
    
    # Set input style to match background (no background reset)
    m.input.style = input_style
    m.input.cursor_style = cursor_style
    m.input.focused = !m.sidebar_focused && m.modal == MODAL_NONE
    m.input.tick = m.tick
    
    # Render input with internal padding
    inner_area = Rect(
        content_x + padding_left, 
        area.y + padding_top, 
        content_width - padding_left - padding_right, 
        area.height - padding_top - padding_bottom
    )
    render(m.input, inner_area, buf)
end

function _render_modal!(m::TuiModel, buf::Buffer, area::Rect)
    if m.modal == MODAL_DELETE_CONFIRM
        _render_delete_modal!(m, buf, area)
    elseif m.modal == MODAL_MODEL_SELECT
        _render_model_select_modal!(m, buf, area)
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

function _render_model_select_modal!(m::TuiModel, buf::Buffer, area::Rect)
    # Title
    title = " Select Model "
    title_style = Style(fg=ColorRGB(100, 255, 100), bold=true)
    
    # Calculate modal dimensions
    modal_width = 50
    modal_height = min(length(m.available_models) + 4, 20)
    modal_rect = center(area, modal_width, modal_height)
    
    # Draw border
    block = Block(
        title=title,
        border_style=Style(fg=Color256(245)),
        title_style=title_style,
        box=BOX_HEAVY,
    )
    content = render(block, modal_rect, buf)
    
    # Render model list inside modal
    m.model_list.tick = m.tick
    m.model_list.focused = true
    list_area = Rect(content.x + 1, content.y + 1, content.width - 2, content.height - 2)
    render(m.model_list, list_area, buf)
    
    # Help text at bottom
    help_y = bottom(content) - 1
    set_string!(buf, content.x + 1, help_y, "Enter:select Esc:cancel", GREY_DIM)
end

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════
function flooty_sessions_tui()
    model = TuiModel()
    
    # Try to load existing sessions from sessions.json
    try
        loaded = load_all_sessions!(model.manager, SESSIONS_FILE)
        if loaded && model.manager.active_session_id !== nothing
            # Restore active session
            if haskey(model.manager.sessions, model.manager.active_session_id)
                model.current_session = model.manager.sessions[model.manager.active_session_id]
            elseif !isempty(model.manager.sessions)
                # Fallback to first session if active not found
                model.current_session = first(values(model.manager.sessions))
                model.manager.active_session_id = model.current_session.id
            end
        elseif !isempty(model.manager.sessions)
            # No active session set, use first
            model.current_session = first(values(model.manager.sessions))
            model.manager.active_session_id = model.current_session.id
        end
    catch e
        @info "No existing sessions found or error loading: $e"
    end
    
    app(model; fps=30)
end

