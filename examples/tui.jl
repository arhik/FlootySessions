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
using FlootyContextManager: add_message!, get_messages, get_full_history
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
    timestamp::Union{Float64, Nothing}
    model::Union{String, Nothing}
    msg_agent_name::Union{String, Nothing}  # Name of the agent that sent this message
    
    function MessageWidget(msg::AbstractMessage, agent_name::String, width::Int; 
                          timestamp=nothing, model=nothing, msg_agent_name=nothing)
        new(msg, agent_name, width, timestamp, model, msg_agent_name)
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
    # Calculate content height with truncation for tool messages
    # For tool messages, skip first line (already shown as header)
    start_line = msg_role == "tool" ? 2 : 1
    max_content_lines = msg_role == "tool" ? 10 : length(lines)
    displayable_lines = max(0, length(lines) - start_line + 1)
    is_truncated = displayable_lines > max_content_lines
    content_height = min(displayable_lines, max_content_lines) + (is_truncated ? 1 : 0)  # +1 for truncation indicator
    
    # Build metadata footer (dim style)
    metadata_parts = String[]
    
    # Add timestamp if available
    if widget.timestamp !== nothing
        dt = Dates.unix2datetime(widget.timestamp)
        time_str = Dates.format(dt, "HH:MM:SS")
        push!(metadata_parts, time_str)
    end
    
    # Add agent name if available (for assistant/tool messages)
    if widget.msg_agent_name !== nothing && !isempty(widget.msg_agent_name) && msg_role != "user"
        push!(metadata_parts, widget.msg_agent_name)
    end
    
    # Add model if available (for assistant messages)
    if widget.model !== nothing && !isempty(widget.model) && msg_role == "assistant"
        # Truncate model name if too long
        model_str = length(widget.model) > 20 ? widget.model[1:20] * "..." : widget.model
        push!(metadata_parts, model_str)
    end
    
    metadata_text = join(metadata_parts, " · ")  # Use middle dot as subtle separator
    has_metadata = !isempty(metadata_text) || is_truncated
    
    # Calculate total height
    # Tool messages have command + separator + output
    # All messages have optional metadata footer with gap
    if msg_role == "tool"
        # Tool: command + separator + output + gap + metadata
        header_height = 2  # command line + separator
    else
        header_height = 0  # No header for other messages
    end
    
    # Gap between content and metadata (1 line if metadata exists)
    gap_height = has_metadata ? 1 : 0
    footer_height = has_metadata ? 1 : 0
    total_height = padding_top + header_height + content_height + gap_height + footer_height + padding_bottom
    
    # Fill entire widget background first (including all padding)
    for row_y in y:(y + total_height - 1)
        row_y >= max_y && break
        for cx in x:(x + widget.width - 1)
            set_char!(buf, cx, row_y, ' ', base_style)
        end
    end
    
    content_start_y = y + padding_top
    
    # Tool messages: show command header with separator
    if msg_role == "tool"
        # Parse tool name and args from first line of content
        header = "\$ tool"
        trimmed_content = strip(msg_content)
        if !isempty(trimmed_content) && startswith(trimmed_content, "\$")
            first_newline = findfirst('\n', trimmed_content)
            if first_newline !== nothing
                header = trimmed_content[1:first_newline-1]
            else
                header = trimmed_content
            end
        end
        
        # Tool header style (same as content for seamless look)
        header_y = content_start_y
        header_y >= max_y && return total_height
        set_string!(buf, x + padding_left, header_y, header, base_style)
        
        # Add separator line after tool command
        sep_y = header_y + 1
        sep_y >= max_y && return total_height
        sep_width = widget.width - padding_left - padding_right
        separator = repeat("─", sep_width)
        set_string!(buf, x + padding_left, sep_y, separator, base_style)
        content_start_y = sep_y + 1
    end
    
    # Content lines - with truncation for tool messages
    # For tool messages, skip first line (already shown as header)
    start_line = msg_role == "tool" ? 2 : 1
    max_content_lines = msg_role == "tool" ? 10 : length(lines)
    is_truncated = (length(lines) - start_line + 1) > max_content_lines
    
    line_idx = 0
    for i in start_line:min(length(lines), start_line + max_content_lines - 1)
        line = lines[i]
        line_y = content_start_y + line_idx
        line_idx += 1
        line_y >= max_y - padding_bottom - gap_height - footer_height && break
        set_string!(buf, x + padding_left, line_y, line, base_style)
    end
    
    # Add truncation indicator if needed
    if is_truncated
        trunc_y = content_start_y + line_idx
        if trunc_y < max_y - padding_bottom - gap_height - footer_height
            total_output_lines = length(lines) - start_line + 1
            trunc_text = "... ($(total_output_lines - max_content_lines) lines truncated)"
            trunc_style = Style(fg=ColorRGB(150, 150, 150), bg=base_style.bg, italic=true)
            set_string!(buf, x + padding_left, trunc_y, trunc_text, trunc_style)
        end
    end
    
    # Metadata footer (dim style) - with gap above it
    if has_metadata || is_truncated
        footer_y = y + total_height - padding_bottom - 1
        footer_y >= max_y && return total_height
        
        # Add truncation info to metadata
        if is_truncated
            total_output_lines = length(lines) - start_line + 1
            metadata_text = "$(total_output_lines - max_content_lines) more lines · " * metadata_text
        end
        
        # Dim style for metadata - darker text on same background
        dim_style = if msg_role == "user"
            Style(fg=ColorRGB(120, 120, 120), bg=ColorRGB(60, 60, 60))  # Darker grey
        elseif msg_role == "assistant"
            Style(fg=ColorRGB(100, 100, 140), bg=ColorRGB(40, 40, 60))  # Darker purple
        elseif msg_role == "tool"
            Style(fg=ColorRGB(100, 140, 100), bg=ColorRGB(40, 80, 40))  # Darker green
        else
            Style(fg=ColorRGB(140, 120, 100), bg=ColorRGB(80, 60, 40))  # Darker orange
        end
        
        set_string!(buf, x + padding_left, footer_y, metadata_text, dim_style)
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
                # Hard wrap long lines - use character indices, not byte indices
                # Use first/last with ncodeunits for proper Unicode handling
                chars = collect(line)
                for i in 1:width:length(chars)
                    end_idx = min(i + width - 1, length(chars))
                    push!(lines, join(chars[i:end_idx]))
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
# Unified Card Widget - Used for both messages and sessions
# ═══════════════════════════════════════════════════════════════════════
mutable struct CardWidget
    title::String
    subtitle::Union{String,Nothing}
    metadata::Union{String,Nothing}
    width::Int
    is_active::Bool
    is_selected::Bool
    card_type::Symbol  # :message_user, :message_assistant, :message_tool, :message_system, :session
    
    function CardWidget(title::String, width::Int; 
                       subtitle=nothing, metadata=nothing, 
                       is_active=false, is_selected=false, card_type=:session)
        new(title, subtitle, metadata, width, is_active, is_selected, card_type)
    end
end

function render_card(buf::Buffer, widget::CardWidget, x::Int, y::Int, max_y::Int)::Int
    y >= max_y && return 0
    
    padding_top = 1
    padding_bottom = 1
    padding_left = 2
    padding_right = 2
    
    # Determine colors based on card type and state
    bg_color, fg_color, accent_color, meta_color = if widget.card_type == :message_user
        (ColorRGB(60, 60, 60), ColorRGB(255, 255, 255), ColorRGB(180, 180, 180), ColorRGB(100, 100, 100))
    elseif widget.card_type == :message_assistant
        (ColorRGB(40, 40, 60), ColorRGB(200, 200, 255), ColorRGB(150, 150, 200), ColorRGB(80, 80, 120))
    elseif widget.card_type == :message_tool
        (ColorRGB(40, 80, 40), ColorRGB(200, 255, 200), ColorRGB(150, 200, 150), ColorRGB(80, 120, 80))
    elseif widget.card_type == :message_system
        (ColorRGB(80, 60, 40), ColorRGB(255, 220, 180), ColorRGB(200, 180, 150), ColorRGB(120, 100, 80))
    elseif widget.card_type == :session
        if widget.is_active
            (ColorRGB(50, 50, 70), ColorRGB(255, 255, 100), ColorRGB(100, 255, 100), ColorRGB(80, 80, 100))
        elseif widget.is_selected
            (ColorRGB(50, 50, 50), ColorRGB(200, 200, 200), ColorRGB(150, 150, 150), ColorRGB(80, 80, 80))
        else
            (ColorRGB(40, 40, 40), ColorRGB(180, 180, 180), ColorRGB(100, 100, 100), ColorRGB(70, 70, 70))
        end
    else
        (ColorRGB(50, 50, 50), ColorRGB(200, 200, 200), ColorRGB(150, 150, 150), ColorRGB(80, 80, 80))
    end
    
    base_style = Style(bg=bg_color, fg=fg_color)
    dim_style = Style(bg=bg_color, fg=accent_color)
    meta_style = Style(bg=bg_color, fg=meta_color)  # Even dimmer for metadata
    
    # Calculate content
    content_width = widget.width - padding_left - padding_right
    lines = String[]
    
    # Title line - no arrow, just the title
    push!(lines, widget.title)
    
    # Subtitle if present
    if widget.subtitle !== nothing && !isempty(widget.subtitle)
        push!(lines, widget.subtitle)
    end
    
    content_height = length(lines)
    has_metadata = widget.metadata !== nothing && !isempty(widget.metadata)
    
    # Calculate total height
    gap_height = has_metadata ? 1 : 0
    footer_height = has_metadata ? 1 : 0
    total_height = padding_top + content_height + gap_height + footer_height + padding_bottom
    
    # Draw background
    for row_y in y:(y + total_height - 1)
        row_y >= max_y && break
        for cx in x:(x + widget.width - 1)
            set_char!(buf, cx, row_y, ' ', base_style)
        end
    end
    
    # Draw left border/accent
    border_char = widget.is_active ? '▌' : '│'
    border_style = widget.is_active ? Style(fg=accent_color, bg=bg_color) : Style(fg=ColorRGB(80, 80, 80), bg=bg_color)
    for row_y in y:(y + total_height - 1)
        row_y >= max_y && break
        set_char!(buf, x, row_y, border_char, border_style)
    end
    
    # Draw content
    content_start_y = y + padding_top
    for (i, line) in enumerate(lines)
        line_y = content_start_y + (i - 1)
        line_y >= max_y - padding_bottom - gap_height - footer_height && break
        set_string!(buf, x + padding_left, line_y, line, i == 1 ? base_style : dim_style)
    end
    
    # Draw metadata footer (very dim)
    if has_metadata
        footer_y = y + total_height - padding_bottom - 1
        footer_y >= max_y && return total_height
        set_string!(buf, x + padding_left, footer_y, widget.metadata, meta_style)
    end
    
    return total_height
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
    streaming_session_id::Union{UUID,Nothing} = nothing  # Track which session is streaming
    show_sidebar::Bool = true
    sidebar_focused::Bool = false
    scroll_offset::Int = 0
    last_message_count::Int = 0  # Track message count for auto-scroll
    last_content_hash::UInt = 0  # Track content changes for auto-scroll
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
    
    # Chat scroll (always works regardless of focus)
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
    
    # Sidebar navigation
    if m.sidebar_focused && m.show_sidebar
        handled = handle_key!(m.session_list, evt)
        if handled
            _switch_to_session!(m, m.session_list.selected)
        end
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
    # Handle mouse clicks in sidebar
    # MouseEvent has: x, y, button, action, shift, alt, ctrl
    
    if evt.action == :press && evt.button == 1  # Left click
        # Check if click is in sidebar area
        sidebar_width = m.show_sidebar ? 35 : 0
        if evt.x <= sidebar_width && evt.y >= 2  # Below title
            sessions = list_sessions(m.manager)
            
            # Calculate card height based on whether there's metadata
            # Card height = padding(2) + title(1) + gap(1 if metadata) + metadata(1 if metadata)
            card_start_y = 2
            cumulative_height = 0
            clicked_idx = 0
            
            for (i, session) in enumerate(sessions)
                msg_count = session.root_agent !== nothing ? 
                           length(get_messages(session.root_agent.context)) : 0
                has_metadata = msg_count > 0
                card_height = has_metadata ? 4 : 3  # 4 with metadata, 3 without
                
                if evt.y >= card_start_y + cumulative_height && 
                   evt.y < card_start_y + cumulative_height + card_height
                    clicked_idx = i
                    break
                end
                cumulative_height += card_height + 1  # +1 for spacing between cards
            end
            
            if clicked_idx >= 1 && clicked_idx <= length(sessions)
                m.sidebar_focused = true
                m.session_list.selected = clicked_idx
                _switch_to_session!(m, clicked_idx)
            end
        end
    elseif evt.action == :scroll_up
        if m.sidebar_focused
            m.session_list.selected = max(1, m.session_list.selected - 1)
        else
            m.scroll_offset = max(0, m.scroll_offset - 3)
        end
    elseif evt.action == :scroll_down
        if m.sidebar_focused
            sessions = list_sessions(m.manager)
            m.session_list.selected = min(length(sessions), m.session_list.selected + 1)
        else
            m.scroll_offset += 3
        end
    end
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
    current_session_id = m.current_session.id
    m.streaming_session_id = current_session_id
    m.last_message_count = 0  # Reset to trigger auto-scroll when response arrives
    m.last_content_hash = 0   # Reset content hash tracking
    
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
        # Only clear if still the same session (don't affect other sessions)
        if m.streaming_session_id == current_session_id
            m.streaming_session_id = nothing
        end
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
    
    m.streaming_session_id !== nothing && push!(parts, "⏳ streaming")
    
    push!(parts, "F2:sidebar F3:new F4:delete F5:save F6:model End:bottom Ctrl+C:quit")
    
    join(parts, " | ")
end

function _render_sidebar!(m::TuiModel, buf::Buffer, area::Rect)
    # Title
    title = " Sessions "
    title_x = center(area, length(title), 1).x
    set_string!(buf, title_x, area.y, title, HIGHLIGHT)
    
    # Session cards
    sessions = list_sessions(m.manager)
    active_id = m.manager.active_session_id
    
    card_area = Rect(area.x + 1, area.y + 2, area.width - 2, area.height - 4)
    y = card_area.y
    
    for (i, session) in enumerate(sessions)
        y >= bottom(card_area) && break
        
        is_active = session.id == active_id
        is_selected = m.sidebar_focused && m.session_list.selected == i
        
        # Build metadata with status indicator
        msg_count = session.root_agent !== nothing ? 
                   length(get_messages(session.root_agent.context)) : 0
        
        # Status indicator based on session state
        status_indicator = ""
        is_this_session_streaming = m.streaming_session_id == session.id
        if is_this_session_streaming
            # Animated spinner for streaming session
            spinners = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
            spinner_idx = (m.tick ÷ 5) % length(spinners) + 1
            status_indicator = string(spinners[spinner_idx]) * " "
        elseif is_active
            status_indicator = "● "  # Solid dot for active
        elseif session.status == SESSION_PAUSED
            status_indicator = "○ "  # Hollow dot for paused
        else
            status_indicator = "  "  # No indicator
        end
        
        metadata = status_indicator * "$(msg_count) msgs"
        
        card = CardWidget(
            session.name,
            card_area.width;
            subtitle=nothing,
            metadata=metadata,
            is_active=is_active,
            is_selected=is_selected,
            card_type=:session
        )
        
        h = render_card(buf, card, card_area.x, y, bottom(card_area))
        y += h + 1  # +1 for spacing between cards
    end
    
    # Help text at bottom
    help_y = bottom(area) - 2
    set_string!(buf, area.x + 1, help_y, "F3: New", GREY_DIM)
    set_string!(buf, area.x + 1, help_y + 1, "F4: Delete", GREY_DIM)
end

function _render_chat!(m::TuiModel, buf::Buffer, area::Rect)
    m.current_session === nothing && return
    m.current_session.root_agent === nothing && return
    
    agent = m.current_session.root_agent
    # Use get_full_history to get ContextMessage with timestamps
    context_messages = get_full_history(agent.context)
    
    # Calculate scrollbar area (right side of chat)
    scrollbar_width = 1
    content_width = area.width - scrollbar_width - 2  # -2 for left/right padding
    content_area = Rect(area.x + 1, area.y, content_width, area.height)
    scrollbar_area = Rect(right(content_area), area.y, scrollbar_width, area.height)
    
    # Calculate total content height and content hash
    total_height = 0
    content_hash = zero(UInt)
    for ctx_msg in context_messages
        widget = MessageWidget(ctx_msg.message, agent.name, content_width;
                              timestamp=ctx_msg.timestamp,
                              model=agent.model,
                              msg_agent_name=agent.name)
        total_height += _calculate_widget_height(widget) + 1  # +1 for spacing
        # Hash the message content to detect changes
        msg_content = FlootyAbstract.content(ctx_msg.message)
        if msg_content !== nothing
            content_hash = hash(msg_content, content_hash)
        end
    end
    
    # Auto-scroll to bottom on new messages, content changes, or End key
    current_message_count = length(context_messages)
    has_new_messages = current_message_count > m.last_message_count
    has_content_changed = content_hash != m.last_content_hash
    
    if m.scroll_offset < 0 ||              # User pressed End key
       has_new_messages ||                 # New message arrived
       has_content_changed                  # Message content changed (e.g., tool output)
        m.scroll_offset = max(0, total_height - area.height)
    end
    
    # Update tracking for next frame
    m.last_message_count = current_message_count
    m.last_content_hash = content_hash
    
    # Render messages with padding
    rendered_height = 0
    for ctx_msg in context_messages
        widget = MessageWidget(ctx_msg.message, agent.name, content_width;
                              timestamp=ctx_msg.timestamp,
                              model=agent.model,
                              msg_agent_name=agent.name)
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
    msg_role = role(msg)
    content_str = content(msg) === nothing ? "" : content(msg)
    # Match render_widget: use preserve_whitespace for tool messages
    preserve_ws = msg_role == "tool"
    lines = _wrap_lines(content_str, widget.width - 4; preserve_whitespace=preserve_ws)
    
    # Calculate height based on message type
    padding_top = 1
    padding_bottom = 1
    
    # Tool messages have command + separator
    header_height = msg_role == "tool" ? 2 : 0
    
    # Truncate tool messages to 10 lines (skip first line which is the command)
    start_line = msg_role == "tool" ? 2 : 1
    max_content_lines = msg_role == "tool" ? 10 : length(lines)
    displayable_lines = max(0, length(lines) - start_line + 1)
    is_truncated = displayable_lines > max_content_lines
    content_height = min(displayable_lines, max_content_lines) + (is_truncated ? 1 : 0)
    
    # Metadata footer if we have timestamp or other metadata (or truncation)
    has_metadata = widget.timestamp !== nothing || 
                    (widget.msg_agent_name !== nothing && msg_role != "user") ||
                    (widget.model !== nothing && msg_role == "assistant") ||
                    is_truncated
    gap_height = has_metadata ? 1 : 0  # Gap between content and metadata
    footer_height = has_metadata ? 1 : 0
    
    total = padding_top + header_height + content_height + gap_height + footer_height + padding_bottom
    
    return total
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

