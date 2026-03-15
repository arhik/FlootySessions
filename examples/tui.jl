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
#   F7               - Toggle message select mode (copy/delete messages)
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
using InteractiveUtils

@tachikoma_app

# Import mouse enums for clarity
using Tachikoma: mouse_left, mouse_middle, mouse_right, mouse_scroll_up, mouse_scroll_down
using Tachikoma: mouse_press, mouse_release, mouse_drag, mouse_move

# Enable markdown extension for rendering assistant messages
Tachikoma.enable_markdown()

# Debug logging to file (since @info doesn't show in TUI)
const DEBUG_LOG = Ref{Union{IO,Nothing}}(nothing)
function _init_debug_log!()
    # Clear log on startup
    DEBUG_LOG[] = open("/tmp/tui.log", "w")
    println(DEBUG_LOG[], "[$(Dates.format(now(), "HH:MM:SS"))] TUI started")
    flush(DEBUG_LOG[])
end
function _debug_log(msg::String)
    if DEBUG_LOG[] === nothing
        _init_debug_log!()
    end
    println(DEBUG_LOG[], "[$(Dates.format(now(), "HH:MM:SS"))] $msg")
    flush(DEBUG_LOG[])
end

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
    is_selected::Bool  # Whether this message is selected for actions
    
    function MessageWidget(msg::AbstractMessage, agent_name::String, width::Int; 
                          timestamp=nothing, model=nothing, msg_agent_name=nothing, is_selected=false)
        new(msg, agent_name, width, timestamp, model, msg_agent_name, is_selected)
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
    
    # Determine base style - brighter when selected
    base_style = if widget.is_selected
        # Selected state - brighter/highlighted
        if msg_role == "user"
            Style(bg=ColorRGB(80, 80, 80), fg=ColorRGB(255, 255, 255))
        elseif msg_role == "assistant"
            Style(bg=ColorRGB(60, 60, 100), fg=ColorRGB(220, 220, 255))
        elseif msg_role == "tool"
            if occursin("\nError:", msg_content) || startswith(msg_content, "Error:")
                Style(bg=ColorRGB(120, 60, 60), fg=ColorRGB(255, 220, 220))
            else
                Style(bg=ColorRGB(60, 120, 60), fg=ColorRGB(220, 255, 220))
            end
        else
            Style(bg=ColorRGB(100, 80, 60), fg=ColorRGB(255, 240, 200))
        end
    else
        # Normal state
        if msg_role == "user"
            Style(bg=ColorRGB(60, 60, 60), fg=ColorRGB(255, 255, 255))
        elseif msg_role == "assistant"
            Style(bg=ColorRGB(40, 40, 60), fg=ColorRGB(200, 200, 255))
        elseif msg_role == "tool"
            if occursin("\nError:", msg_content) || startswith(msg_content, "Error:")
                Style(bg=ColorRGB(80, 40, 40), fg=ColorRGB(255, 200, 200))
            else
                Style(bg=ColorRGB(40, 80, 40), fg=ColorRGB(200, 255, 200))
            end
        else
            Style(bg=ColorRGB(80, 60, 40), fg=ColorRGB(255, 220, 180))
        end
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
    
    # For assistant messages with markdown, calculate height from markdown rendering
    if msg_role == "assistant" && Tachikoma.markdown_extension_loaded()
        md_lines = Tachikoma.markdown_to_spans(msg_content, content_width)
        content_height = length(md_lines)
    else
        content_height = min(displayable_lines, max_content_lines) + (is_truncated ? 1 : 0)  # +1 for truncation indicator
    end
    
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
    
    # Use markdown rendering for assistant messages
    if msg_role == "assistant" && Tachikoma.markdown_extension_loaded()
        # Render markdown content
        md_lines = Tachikoma.markdown_to_spans(msg_content, content_width)
        line_idx = 0
        for md_line in md_lines
            line_y = content_start_y + line_idx
            line_idx += 1
            line_y >= max_y - padding_bottom - gap_height - footer_height && break
            # Render each span in the line
            current_x = x + padding_left
            for span in md_line
                # Access Span fields directly
                span_text = span.content
                span_style = span.style
                # Merge with base background
                merged_style = Style(
                    fg=span_style.fg,
                    bg=base_style.bg,  # Keep message background
                    bold=span_style.bold,
                    dim=span_style.dim,
                    italic=span_style.italic,
                    underline=span_style.underline
                )
                set_string!(buf, current_x, line_y, span_text, merged_style)
                current_x += length(span_text)
            end
        end
    else
        # Standard text rendering for user/tool messages
        line_idx = 0
        for i in start_line:min(length(lines), start_line + max_content_lines - 1)
            line = lines[i]
            line_y = content_start_y + line_idx
            line_idx += 1
            line_y >= max_y - padding_bottom - gap_height - footer_height && break
            set_string!(buf, x + padding_left, line_y, line, base_style)
        end
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
    # accent_color is used for the left border/handler
    bg_color, fg_color, accent_color, meta_color = if widget.card_type == :message_user
        (ColorRGB(60, 60, 60), ColorRGB(255, 255, 255), ColorRGB(180, 180, 180), ColorRGB(100, 100, 100))
    elseif widget.card_type == :message_assistant
        (ColorRGB(40, 40, 60), ColorRGB(200, 200, 255), ColorRGB(150, 150, 200), ColorRGB(80, 80, 120))
    elseif widget.card_type == :message_tool
        (ColorRGB(40, 80, 40), ColorRGB(200, 255, 200), ColorRGB(150, 200, 150), ColorRGB(80, 120, 80))
    elseif widget.card_type == :message_system
        (ColorRGB(80, 60, 40), ColorRGB(255, 220, 180), ColorRGB(200, 180, 150), ColorRGB(120, 100, 80))
    elseif widget.card_type == :session
        # Sessions: all have handlers, active = green, inactive = light grey
        if widget.is_active
            # Active: bright green handler
            (ColorRGB(45, 45, 45), ColorRGB(220, 220, 220), ColorRGB(150, 255, 150), ColorRGB(100, 100, 100))
        elseif widget.is_selected
            # Selected but not active: darker grey handler
            (ColorRGB(40, 40, 40), ColorRGB(200, 200, 200), ColorRGB(100, 100, 100), ColorRGB(80, 80, 80))
        else
            # Inactive: light grey handler
            (ColorRGB(40, 40, 40), ColorRGB(180, 180, 180), ColorRGB(150, 150, 150), ColorRGB(70, 70, 70))
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
    # Use accent_color for all states (active=bright, inactive=grey, selected=medium)
    border_char = widget.is_active ? '▌' : '│'
    border_style = Style(fg=accent_color, bg=bg_color)
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
    
    # Message selection for actions
    selected_message_idx::Union{Int,Nothing} = nothing  # Index of selected message (1-based)
    message_select_mode::Bool = false  # When true, Up/Down navigate messages instead of sessions
    
    # Layout cache for mouse handling (updated in view, used in mouse handler)
    layout_sidebar_width::Int = 0
    layout_sidebar_y::Int = 0  # Sidebar starts at this Y position
    layout_card_width::Int = 0  # Card width (sidebar_width - 2 for borders)
    layout_chat_x::Int = 0
    layout_chat_width::Int = 0
    layout_content_width::Int = 0
    layout_chat_y::Int = 0
    layout_chat_height::Int = 0
    
    # Sidebar scrolling
    sidebar_scroll_offset::Int = 0  # Scroll offset for session list
    
    # Message queue for when LLM is busy
    message_queue::Vector{String} = String[]  # Queued messages to send when LLM is free
    selected_queue_idx::Union{Int,Nothing} = nothing  # Selected queued message
    queue_select_mode::Bool = false  # When true, navigating queued messages
    queue_scroll_offset::Int = 0  # Scroll offset for queue panel
    
    # Status notification
    status_message::String = ""
    status_ttl::Int = 0  # Frames remaining to show status
    
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
        _debug_log("MouseEvent: x=$(evt.x), y=$(evt.y), button=$(evt.button), action=$(evt.action)")
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
    
    # Message selection mode (toggle with F7 key)
    if evt.key == :f7 && !m.sidebar_focused
        m.message_select_mode = !m.message_select_mode
        if m.message_select_mode
            # Enter select mode - select last message
            m.current_session === nothing && return
            m.current_session.root_agent === nothing && return
            context_messages = get_full_history(m.current_session.root_agent.context)
            m.selected_message_idx = length(context_messages) > 0 ? length(context_messages) : nothing
        else
            # Exit select mode
            m.selected_message_idx = nothing
        end
        return
    end
    
    # Message navigation when in select mode
    if m.message_select_mode && m.selected_message_idx !== nothing
        if evt.key == :up
            m.selected_message_idx = max(1, m.selected_message_idx - 1)
            return
        elseif evt.key == :down
            m.current_session === nothing && return
            m.current_session.root_agent === nothing && return
            context_messages = get_full_history(m.current_session.root_agent.context)
            m.selected_message_idx = min(length(context_messages), m.selected_message_idx + 1)
            return
        elseif evt.key == :char && evt.char == 'c'
            # Copy selected message
            _copy_selected_message!(m)
            return
        elseif evt.key == :char && evt.char == 'd'
            # Delete selected message
            _delete_selected_message!(m)
            return
        elseif evt.key == :escape
            # Exit select mode
            m.message_select_mode = false
            m.selected_message_idx = nothing
            return
        end
    end
    
    # Queue selection mode (toggle with 'q' key when queue has items)
    if evt.key == :char && evt.char == 'q' && !isempty(m.message_queue) && !m.sidebar_focused
        m.queue_select_mode = !m.queue_select_mode
        if m.queue_select_mode
            # Enter queue select mode - select first item
            m.selected_queue_idx = 1
        else
            # Exit select mode
            m.selected_queue_idx = nothing
        end
        return
    end
    
    # Queue navigation when in select mode
    if m.queue_select_mode && m.selected_queue_idx !== nothing
        if evt.key == :up
            m.selected_queue_idx = max(1, m.selected_queue_idx - 1)
            return
        elseif evt.key == :down
            m.selected_queue_idx = min(length(m.message_queue), m.selected_queue_idx + 1)
            return
        elseif evt.key == :pageup
            m.selected_queue_idx = max(1, m.selected_queue_idx - 3)
            m.queue_scroll_offset = max(0, m.queue_scroll_offset - 3)
            return
        elseif evt.key == :pagedown
            m.selected_queue_idx = min(length(m.message_queue), m.selected_queue_idx + 3)
            m.queue_scroll_offset = min(max(0, length(m.message_queue) - 3), m.queue_scroll_offset + 3)
            return
        elseif evt.key == :char && evt.char == 'c'
            # Copy selected queued message
            if m.selected_queue_idx <= length(m.message_queue)
                try
                    clipboard(m.message_queue[m.selected_queue_idx])
                    _set_status!(m, "Copied queued message $m.selected_queue_idx")
                catch e
                    _set_status!(m, "Failed to copy: $e")
                end
            end
            return
        elseif evt.key == :char && evt.char == 'd'
            # Delete selected queued message
            if m.selected_queue_idx <= length(m.message_queue)
                deleted_msg = splice!(m.message_queue, m.selected_queue_idx)
                _set_status!(m, "Deleted: $(length(deleted_msg) > 20 ? deleted_msg[1:20]*"..." : deleted_msg)")
                # Adjust selection
                if isempty(m.message_queue)
                    m.queue_select_mode = false
                    m.selected_queue_idx = nothing
                    m.queue_scroll_offset = 0
                elseif m.selected_queue_idx > length(m.message_queue)
                    m.selected_queue_idx = length(m.message_queue)
                end
            end
            return
        elseif evt.key == :escape
            # Exit select mode
            m.queue_select_mode = false
            m.selected_queue_idx = nothing
            return
        end
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
        text = String(strip(String(m.input.buffer)))
        if !handled && !isempty(text)
            is_this_session_streaming = m.current_session !== nothing && m.streaming_session_id == m.current_session.id
            
            if evt.key == :enter || (evt.key == :char && evt.char == '\n')
                if is_this_session_streaming
                    # Queue message when Enter pressed while streaming
                    push!(m.message_queue, text)
                    empty!(m.input.buffer)
                    m.input.cursor = 0
                    _set_status!(m, "Message queued ($(length(m.message_queue)))")
                else
                    _send_message!(m)
                end
            elseif (evt.key == :shift_enter || (evt.shift && (evt.key == :enter || (evt.key == :char && evt.char == '\n')))) && is_this_session_streaming
                # Shift+Enter to force send (cancel current and send new)
                m.streaming_session_id = nothing  # Cancel current streaming
                _send_message!(m)  # Send immediately
                _set_status!(m, "Force sent (cancelled previous)")
            end
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
    # Handle mouse clicks in sidebar, chat, and queue
    # MouseEvent has: x, y, button, action, shift, alt, ctrl
    
    sidebar_width = m.layout_sidebar_width > 0 ? m.layout_sidebar_width : (m.show_sidebar ? 35 : 0)
    
    _debug_log("Mouse: x=$(evt.x), y=$(evt.y), sidebar_width=$sidebar_width, chat_x=$(m.layout_chat_x), chat_width=$(m.layout_chat_width), action=$(evt.action), button=$(evt.button)")
    
    # Calculate queue area Y position (from view function layout)
    status_height = 1
    input_height = 3
    activity_height = 1
    queue_height = isempty(m.message_queue) ? 0 : min(length(m.message_queue), 5)
    
    status_y = m.layout_chat_y + m.layout_chat_height + activity_height + queue_height + input_height
    input_y = status_y - input_height
    queue_y = input_y - queue_height
    activity_y = queue_y - activity_height
    
    # Use Tachikoma's MouseAction and MouseButton enums
    if evt.action == mouse_press && evt.button == mouse_left
        if evt.x <= sidebar_width && evt.y >= 1  # Click in sidebar
            _debug_log("Click in SIDEBAR (x=$(evt.x) <= $sidebar_width)")
            _handle_sidebar_click!(m, evt)
        elseif queue_height > 0 && evt.y >= queue_y && evt.y < queue_y + queue_height && evt.x > sidebar_width
            # Click in queue area
            _debug_log("Click in QUEUE (y=$(evt.y), queue_y=$queue_y, height=$queue_height)")
            _handle_queue_click!(m, evt, sidebar_width, queue_y)
        else  # Click in chat area
            _debug_log("Click in CHAT (x=$(evt.x) > $sidebar_width)")
            _handle_chat_click!(m, evt, sidebar_width)
        end
    elseif evt.button == mouse_scroll_up && evt.action == mouse_press
        _debug_log("Scroll up")
        if m.sidebar_focused
            m.sidebar_scroll_offset = max(0, m.sidebar_scroll_offset - 3)
        elseif m.queue_select_mode && !isempty(m.message_queue)
            m.queue_scroll_offset = max(0, m.queue_scroll_offset - 1)
        else
            m.scroll_offset = max(0, m.scroll_offset - 3)
        end
    elseif evt.button == mouse_scroll_down && evt.action == mouse_press
        _debug_log("Scroll down")
        if m.sidebar_focused
            sessions = list_sessions(m.manager)
            total_height = 0
            active_id = m.manager.active_session_id
            for session in sessions
                msg_count = session.root_agent !== nothing ? 
                           length(get_messages(session.root_agent.context)) : 0
                status_indicator = if m.streaming_session_id == session.id
                    "⠋ "
                elseif session.id == active_id
                    "● "
                elseif session.status == SESSION_PAUSED
                    "○ "
                else
                    "  "
                end
                metadata = status_indicator * "$(msg_count) msgs"
                card_width = m.layout_card_width > 0 ? m.layout_card_width : 33
                card = CardWidget(session.name, card_width; subtitle=nothing, metadata=metadata,
                                 is_active=session.id == active_id, is_selected=false, card_type=:session)
                total_height += _calculate_card_height(card) + 1
            end
            sidebar_height = m.layout_chat_height > 0 ? m.layout_chat_height - 1 : 90
            m.sidebar_scroll_offset = min(max(0, total_height - sidebar_height), m.sidebar_scroll_offset + 3)
        elseif m.queue_select_mode && !isempty(m.message_queue)
            m.queue_scroll_offset = min(max(0, length(m.message_queue) - 5), m.queue_scroll_offset + 1)
        else
            m.scroll_offset += 3
        end
    end
end

function _handle_sidebar_click!(m::TuiModel, evt::MouseEvent)
    sessions = list_sessions(m.manager)
    
    # Cards start at layout_sidebar_y (top of sidebar area, 1-based coordinates)
    # Account for sidebar scroll offset
    card_start_y = (m.layout_sidebar_y > 0 ? m.layout_sidebar_y : 1) - m.sidebar_scroll_offset
    
    _debug_log("Sidebar click: evt.y=$(evt.y), sidebar_y=$(m.layout_sidebar_y), scroll=$(m.sidebar_scroll_offset), card_start_y=$card_start_y, $(length(sessions)) sessions")
    
    cumulative_height = 0
    clicked_idx = 0
    
    for (i, session) in enumerate(sessions)
        msg_count = session.root_agent !== nothing ? 
                   length(get_messages(session.root_agent.context)) : 0
        has_metadata = msg_count > 0
        
        # Build card to get actual height (same as in _render_sidebar!)
        # Use cached card width to ensure consistency with render
        card_width = m.layout_card_width > 0 ? m.layout_card_width : 33
        
        # Match metadata format EXACTLY as in _render_sidebar!
        is_active = session.id == m.manager.active_session_id
        is_this_session_streaming = m.streaming_session_id == session.id
        status_indicator = if is_this_session_streaming
            spinners = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
            spinner_idx = (m.tick ÷ 5) % length(spinners) + 1
            string(spinners[spinner_idx]) * " "
        elseif is_active
            "● "
        elseif session.status == SESSION_PAUSED
            "○ "
        else
            "  "
        end
        metadata = status_indicator * "$(msg_count) msgs"
        
        card = CardWidget(
            session.name, card_width;  # Use cached width for consistency
            subtitle=nothing,
            metadata=metadata,
            is_active=is_active,
            is_selected=m.session_list.selected == i,
            card_type=:session
        )
        card_height = _calculate_card_height(card)
        
        card_y_start = card_start_y + cumulative_height
        card_y_end = card_y_start + card_height
        
        _debug_log("MOUSE session $i: y=$card_y_start-$card_y_end, height=$card_height, card_width=$card_width, name='$(session.name)'")
        
        if evt.y >= card_y_start && evt.y < card_y_end
            clicked_idx = i
            _debug_log("CLICKED session $i")
            break
        end
        cumulative_height += card_height + 1  # +1 for spacing
    end
    
    if clicked_idx >= 1 && clicked_idx <= length(sessions)
        m.sidebar_focused = true
        m.session_list.selected = clicked_idx
        _switch_to_session!(m, clicked_idx)
        _debug_log("Switched to session $clicked_idx")
    else
        _debug_log("No session clicked (checked $(length(sessions)) sessions)")
    end
end

function _handle_queue_click!(m::TuiModel, evt::MouseEvent, sidebar_width::Int, queue_y::Int)
    isempty(m.message_queue) && return
    
    # Enter queue select mode
    m.queue_select_mode = true
    m.sidebar_focused = false
    
    # Calculate which item was clicked
    clicked_idx = evt.y - queue_y + 1 + m.queue_scroll_offset
    
    _debug_log("Queue click: evt.y=$(evt.y), queue_y=$queue_y, scroll=$(m.queue_scroll_offset), clicked_idx=$clicked_idx")
    
    if clicked_idx >= 1 && clicked_idx <= length(m.message_queue)
        m.selected_queue_idx = clicked_idx
        _debug_log("Selected queue item $clicked_idx")
    else
        _debug_log("No queue item clicked")
    end
end

function _handle_chat_click!(m::TuiModel, evt::MouseEvent, sidebar_width::Int)
    m.current_session === nothing && return
    m.current_session.root_agent === nothing && return
    
    # Use cached layout values
    chat_x = m.layout_chat_x > 0 ? m.layout_chat_x : sidebar_width + 1
    content_width = m.layout_content_width > 0 ? m.layout_content_width : 50
    chat_y = m.layout_chat_y > 0 ? m.layout_chat_y : 1
    chat_height = m.layout_chat_height > 0 ? m.layout_chat_height : 24
    
    _debug_log("Chat click: x=$(evt.x), y=$(evt.y), chat_x=$chat_x, content_width=$content_width, chat_y=$chat_y, chat_height=$chat_height, scroll_offset=$(m.scroll_offset)")
    
    # Check if click is within chat content area
    if evt.x < chat_x + 1
        _debug_log("Click too far left (x < $(chat_x + 1))")
        return
    end
    if evt.x > chat_x + content_width
        _debug_log("Click in scrollbar area (x > $(chat_x + content_width))")
        return
    end
    if evt.y < chat_y
        _debug_log("Click above chat area (y < $chat_y)")
        return
    end
    if evt.y >= chat_y + chat_height
        _debug_log("Click below chat area (y >= $(chat_y + chat_height))")
        return
    end
    
    agent = m.current_session.root_agent
    context_messages = get_full_history(agent.context)
    
    # Find which message was clicked
    # The visible area is from chat_y to chat_y + chat_height
    # Messages are positioned at: chat_y - scroll_offset + cumulative_height
    # We need to find which message contains evt.y in its visible portion
    
    cumulative_height = 0
    clicked_idx = 0
    
    for (i, ctx_msg) in enumerate(context_messages)
        widget = MessageWidget(ctx_msg.message, agent.name, content_width;
                              timestamp=ctx_msg.timestamp,
                              model=agent.model,
                              msg_agent_name=agent.name)
        msg_height = _calculate_widget_height(widget)
        
        # Calculate message position (same as in _render_chat!)
        msg_y_start = chat_y - m.scroll_offset + cumulative_height
        msg_y_end = msg_y_start + msg_height
        
        # Check if message is visible and if click is inside it
        msg_visible = msg_y_end > chat_y && msg_y_start < chat_y + chat_height
        click_inside = evt.y >= msg_y_start && evt.y < msg_y_end
        
        if msg_visible
            _debug_log("Message $i: y=$msg_y_start-$msg_y_end, visible=$msg_visible, click_inside=$click_inside")
        end
        
        if click_inside
            clicked_idx = i
            _debug_log("CLICKED message $i")
            break
        end
        cumulative_height += msg_height + 1  # +1 for spacing
    end
    
    if clicked_idx >= 1 && clicked_idx <= length(context_messages)
        # Enter message select mode and select clicked message
        m.message_select_mode = true
        m.selected_message_idx = clicked_idx
        m.sidebar_focused = false
        _set_status!(m, "Selected message $clicked_idx")
        _debug_log("Selected message $clicked_idx")
    else
        _debug_log("No message clicked (checked $(length(context_messages)) messages)")
    end
end

function _calculate_card_height(card::CardWidget)::Int
    # Match render_card logic
    padding_top = 1
    padding_bottom = 1
    
    content_height = 1  # Title line
    if card.subtitle !== nothing && !isempty(card.subtitle)
        content_height += 1
    end
    
    has_metadata = card.metadata !== nothing && !isempty(card.metadata)
    gap_height = has_metadata ? 1 : 0
    footer_height = has_metadata ? 1 : 0
    
    return padding_top + content_height + gap_height + footer_height + padding_bottom
end

function _open_delete_modal!(m::TuiModel)
    m.current_session === nothing && return
    m.modal = MODAL_DELETE_CONFIRM
    m.modal_selected = :cancel
    m.modal_message = "Delete session '$(m.current_session.name)'?"
end

function _set_status!(m::TuiModel, msg::String, ttl::Int=120)
    m.status_message = msg
    m.status_ttl = ttl
end

function _copy_selected_message!(m::TuiModel)
    m.current_session === nothing && return
    m.current_session.root_agent === nothing && return
    m.selected_message_idx === nothing && return
    
    context_messages = get_full_history(m.current_session.root_agent.context)
    m.selected_message_idx < 1 && return
    m.selected_message_idx > length(context_messages) && return
    
    ctx_msg = context_messages[m.selected_message_idx]
    msg_content = FlootyAbstract.content(ctx_msg.message)
    msg_content === nothing && return
    
    # Copy to clipboard using InteractiveUtils
    try
        clipboard(msg_content)
        _set_status!(m, "Copied to clipboard ($(length(msg_content)) chars)")
    catch e
        _set_status!(m, "Failed to copy: $e")
    end
    
    # Exit select mode after copy
    m.message_select_mode = false
    m.selected_message_idx = nothing
end

function _delete_selected_message!(m::TuiModel)
    m.current_session === nothing && return
    m.current_session.root_agent === nothing && return
    m.selected_message_idx === nothing && return
    
    context_messages = get_full_history(m.current_session.root_agent.context)
    m.selected_message_idx < 1 && return
    m.selected_message_idx > length(context_messages) && return
    
    _debug_log("Deleting message at index $(m.selected_message_idx) of $(length(context_messages))")
    
    # Get the ContextMessage to delete (this contains the actual message in the store)
    ctx_msg = context_messages[m.selected_message_idx]
    msg = ctx_msg.message
    msg_role = FlootyAbstract.role(msg)
    
    _debug_log("Message role: $msg_role, message type: $(typeof(msg))")
    
    # Remove from context store directly
    agent = m.current_session.root_agent
    store = agent.context  # This is the ContextStore
    
    _debug_log("Total messages in store: $(length(store.messages))")
    
    # Find and remove the ContextMessage from the store's messages array
    # Compare by the id since that's unique
    idx = findfirst(cm -> cm.id == ctx_msg.id, store.messages)
    
    if idx !== nothing
        _debug_log("Found ContextMessage at index $idx, deleting...")
        deleteat!(store.messages, idx)
        _set_status!(m, "Deleted $msg_role message")
        _debug_log("Deleted successfully, new count: $(length(store.messages))")
    else
        _debug_log("ContextMessage not found in store!")
        _set_status!(m, "Failed: message not found")
    end
    
    # Update selection
    new_count = length(context_messages) - 1
    if m.selected_message_idx > new_count
        m.selected_message_idx = new_count > 0 ? new_count : nothing
        if m.selected_message_idx === nothing
            m.message_select_mode = false
        end
    end
    
    # Save session
    _auto_save!(m)
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
        
        # Process queued messages if any
        if !isempty(m.message_queue) && m.current_session !== nothing && m.current_session.id == current_session_id
            # Get next queued message
            next_text = popfirst!(m.message_queue)
            # Put it in input buffer and send
            m.input.buffer = collect(UInt8, next_text)
            m.input.cursor = length(next_text)
            _set_status!(m, "Sending queued message ($(length(m.message_queue)) remaining)")
            # Small delay to let UI update
            sleep(0.1)
            _send_message!(m)
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
    
    # Layout: [chat] [activity] [queue] [input] [status]
    sidebar_width = m.show_sidebar ? 35 : 0
    chat_width = f.area.width - sidebar_width
    status_height = 1
    activity_height = 1  # Background activity panel
    # Queue panel height = number of queued messages (max 5 to not take too much space)
    queue_height = isempty(m.message_queue) ? 0 : min(length(m.message_queue), 5)
    input_height = 3
    
    # Calculate areas from bottom up
    status_y = f.area.y + f.area.height - status_height
    input_y = status_y - input_height
    queue_y = input_y - queue_height
    activity_y = queue_y - activity_height
    chat_height = activity_y - f.area.y
    
    # Cache layout for mouse handling
    m.layout_sidebar_width = sidebar_width
    m.layout_sidebar_y = f.area.y
    m.layout_card_width = sidebar_width - 2
    m.layout_chat_x = f.area.x + sidebar_width
    m.layout_chat_width = chat_width
    m.layout_content_width = chat_width - 1 - 2
    m.layout_chat_y = f.area.y
    m.layout_chat_height = chat_height
    
    sidebar_area = Rect(f.area.x, f.area.y, sidebar_width, chat_height + activity_height + queue_height + input_height)
    chat_area = Rect(f.area.x + sidebar_width, f.area.y, chat_width, chat_height)
    activity_area = Rect(f.area.x + sidebar_width, activity_y, chat_width, activity_height)
    queue_area = Rect(f.area.x + sidebar_width, queue_y, chat_width, queue_height)
    input_area = Rect(f.area.x + sidebar_width, input_y, chat_width, input_height)
    
    # Draw separator
    if m.show_sidebar
        sep_x = f.area.x + sidebar_width
        sep_end_y = activity_y - 1
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
    
    # Render activity panel (spinner/status)
    _render_activity_panel!(m, buf, activity_area)
    
    # Render queue panel (queued messages)
    if queue_height > 0
        _render_queue_panel!(m, buf, queue_area)
    end
    
    # Render input
    _render_input!(m, buf, input_area)
    
    # Status bar
    status = _build_status(m)
    set_string!(buf, f.area.x, status_y, status, GREY_DIM)
    
    # Render modal if active
    if m.modal != MODAL_NONE
        _render_modal!(m, buf, f.area)
    end
end

function _build_status(m::TuiModel)::String
    # Decrement status TTL
    if m.status_ttl > 0
        m.status_ttl -= 1
        if m.status_ttl == 0
            m.status_message = ""
        end
    end
    
    # Show status message if active
    if !isempty(m.status_message)
        return m.status_message
    end
    
    parts = String[]
    
    # Queue select mode indicator
    if m.queue_select_mode
        push!(parts, "[QUEUE MODE] Up/Down:nav c:copy d:delete Esc:exit")
    # Message select mode indicator
    elseif m.message_select_mode
        push!(parts, "[SELECT MODE] Up/Down:nav c:copy d:delete Esc:exit")
    else
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
        
        push!(parts, "F2:sidebar F3:new F4:delete F5:save F6:model F7:msg q:queue End:bottom Ctrl+C:quit")
    end
    
    join(parts, " | ")
end

function _render_sidebar!(m::TuiModel, buf::Buffer, area::Rect)
    # Session cards (start at top, no title)
    sessions = list_sessions(m.manager)
    active_id = m.manager.active_session_id
    
    # Calculate scrollbar area (right side of sidebar)
    scrollbar_width = 1
    card_width = area.width - scrollbar_width - 2  # -2 for left/right padding
    card_area = Rect(area.x + 1, area.y, card_width, area.height - 1)  # -1 for title
    scrollbar_area = Rect(right(card_area), area.y, scrollbar_width, area.height - 1)
    
    # Calculate total height of all sessions
    total_height = 0
    for session in sessions
        msg_count = session.root_agent !== nothing ? 
                   length(get_messages(session.root_agent.context)) : 0
        has_metadata = msg_count > 0
        status_indicator = if m.streaming_session_id == session.id
            "⠋ "
        elseif session.id == active_id
            "● "
        elseif session.status == SESSION_PAUSED
            "○ "
        else
            "  "
        end
        metadata = status_indicator * "$(msg_count) msgs"
        card = CardWidget(session.name, card_width; subtitle=nothing, metadata=metadata, 
                         is_active=session.id == active_id, is_selected=false, card_type=:session)
        total_height += _calculate_card_height(card) + 1  # +1 for spacing
    end
    
    # Auto-scroll to keep selected session visible
    if m.sidebar_focused && m.session_list.selected > 0
        # Calculate position of selected session
        selected_y = 0
        for (i, session) in enumerate(sessions)
            if i == m.session_list.selected
                break
            end
            msg_count = session.root_agent !== nothing ? 
                       length(get_messages(session.root_agent.context)) : 0
            has_metadata = msg_count > 0
            status_indicator = if m.streaming_session_id == session.id
                "⠋ "
            elseif session.id == active_id
                "● "
            elseif session.status == SESSION_PAUSED
                "○ "
            else
                "  "
            end
            metadata = status_indicator * "$(msg_count) msgs"
            card = CardWidget(session.name, card_width; subtitle=nothing, metadata=metadata,
                             is_active=session.id == active_id, is_selected=false, card_type=:session)
            selected_y += _calculate_card_height(card) + 1
        end
        
        # Adjust scroll to keep selected visible
        if selected_y < m.sidebar_scroll_offset
            m.sidebar_scroll_offset = selected_y
        elseif selected_y + 5 > m.sidebar_scroll_offset + card_area.height
            m.sidebar_scroll_offset = max(0, selected_y + 5 - card_area.height)
        end
    end
    
    # Render visible sessions
    y = card_area.y - m.sidebar_scroll_offset
    for (i, session) in enumerate(sessions)
        is_active = session.id == active_id
        is_selected = m.sidebar_focused && m.session_list.selected == i
        
        msg_count = session.root_agent !== nothing ? 
                   length(get_messages(session.root_agent.context)) : 0
        
        status_indicator = ""
        is_this_session_streaming = m.streaming_session_id == session.id
        if is_this_session_streaming
            spinners = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
            spinner_idx = (m.tick ÷ 5) % length(spinners) + 1
            status_indicator = string(spinners[spinner_idx]) * " "
        elseif is_active
            status_indicator = "● "
        elseif session.status == SESSION_PAUSED
            status_indicator = "○ "
        else
            status_indicator = "  "
        end
        
        metadata = status_indicator * "$(msg_count) msgs"
        
        card = CardWidget(
            session.name,
            card_width;
            subtitle=nothing,
            metadata=metadata,
            is_active=is_active,
            is_selected=is_selected,
            card_type=:session
        )
        
        h = _calculate_card_height(card)
        
        # Only render if visible
        if y + h > card_area.y && y < bottom(card_area)
            render_card(buf, card, card_area.x, y, bottom(card_area))
        end
        y += h + 1
    end
    
    # Render scrollbar
    if total_height > card_area.height
        _render_scrollbar!(buf, scrollbar_area, m.sidebar_scroll_offset, total_height, card_area.height)
    end
    
    # Title at bottom with grey color
    title = " Sessions "
    title_x = center(area, length(title), 1).x
    set_string!(buf, title_x, bottom(area) - 1, title, GREY_DIM)
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
    for (idx, ctx_msg) in enumerate(context_messages)
        is_selected = m.message_select_mode && m.selected_message_idx == idx
        widget = MessageWidget(ctx_msg.message, agent.name, content_width;
                              timestamp=ctx_msg.timestamp,
                              model=agent.model,
                              msg_agent_name=agent.name,
                              is_selected=is_selected)
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
    content_width = widget.width - 4
    
    # Calculate height based on message type
    padding_top = 1
    padding_bottom = 1
    
    # Tool messages have command + separator
    header_height = msg_role == "tool" ? 2 : 0
    
    # Calculate content height
    if msg_role == "assistant" && Tachikoma.markdown_extension_loaded()
        # Use markdown rendering for assistant messages
        md_lines = Tachikoma.markdown_to_spans(content_str, content_width)
        content_height = length(md_lines)
        is_truncated = false
    else
        # Match render_widget: use preserve_whitespace for tool messages
        preserve_ws = msg_role == "tool"
        lines = _wrap_lines(content_str, content_width; preserve_whitespace=preserve_ws)
        # Truncate tool messages to 10 lines (skip first line which is the command)
        start_line = msg_role == "tool" ? 2 : 1
        max_content_lines = msg_role == "tool" ? 10 : length(lines)
        displayable_lines = max(0, length(lines) - start_line + 1)
        is_truncated = displayable_lines > max_content_lines
        content_height = min(displayable_lines, max_content_lines) + (is_truncated ? 1 : 0)
    end
    
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
    # Input is always enabled (can type even while streaming)
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

function _render_activity_panel!(m::TuiModel, buf::Buffer, area::Rect)
    # Background activity panel - shows spinner only for CURRENT session
    is_this_session_streaming = m.current_session !== nothing && m.streaming_session_id == m.current_session.id
    if is_this_session_streaming
        spinners = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
        spinner_idx = (m.tick ÷ 5) % length(spinners) + 1
        spinner_char = spinners[spinner_idx]
        
        spinner_text = "$spinner_char Busy..."
        # Green text, no background, with full padding (top, bottom, left, right)
        spinner_style = Style(fg=ColorRGB(150, 255, 150))
        # Apply padding: left=2, top=0 (centered vertically in 1-line area)
        text_x = area.x + 2  # left padding
        text_y = area.y + div(area.height - 1, 2)  # vertical center
        set_string!(buf, text_x, text_y, spinner_text, spinner_style)
    end
end

function _render_queue_panel!(m::TuiModel, buf::Buffer, area::Rect)
    # Queue panel - shows all queued messages as cards like chat messages
    # With scrolling support like chat arena
    if isempty(m.message_queue)
        return
    end
    
    # Calculate total height
    total_height = length(m.message_queue)
    
    # Auto-scroll to keep selected item visible
    if m.queue_select_mode && m.selected_queue_idx !== nothing
        if m.selected_queue_idx <= m.queue_scroll_offset
            m.queue_scroll_offset = max(0, m.selected_queue_idx - 1)
        elseif m.selected_queue_idx > m.queue_scroll_offset + area.height
            m.queue_scroll_offset = min(max(0, total_height - area.height), m.selected_queue_idx - area.height)
        end
    end
    
    # Ensure scroll offset is valid
    m.queue_scroll_offset = max(0, min(m.queue_scroll_offset, max(0, total_height - area.height)))
    
    # Render visible items
    start_idx = m.queue_scroll_offset + 1
    end_idx = min(length(m.message_queue), m.queue_scroll_offset + area.height)
    
    for i in start_idx:end_idx
        y = area.y + (i - start_idx)
        y >= bottom(area) && break
        
        msg = m.message_queue[i]
        is_selected = m.queue_select_mode && m.selected_queue_idx == i
        
        # Colors: normal = grey, selected = brighter grey
        if is_selected
            bg_color = ColorRGB(80, 80, 80)  # Brighter when selected
            fg_color = ColorRGB(255, 255, 255)
            accent_color = ColorRGB(255, 255, 150)  # Brighter amber
        else
            bg_color = ColorRGB(60, 60, 60)  # Normal grey
            fg_color = ColorRGB(255, 255, 255)
            accent_color = ColorRGB(255, 200, 100)  # Amber
        end
        
        # Truncate message if too long
        display_msg = msg
        max_len = area.width - 6  # Account for padding and number prefix
        if length(display_msg) > max_len
            display_msg = display_msg[1:max_len-3] * "..."
        end
        
        # Number prefix: "1: message"
        prefix = "$i: "
        full_text = prefix * display_msg
        
        # Draw background for this queued message
        base_style = Style(bg=bg_color, fg=fg_color)
        for cx in area.x:(area.x + area.width - 1)
            set_char!(buf, cx, y, ' ', base_style)
        end
        
        # Draw left border (thicker when selected)
        border_char = is_selected ? '▌' : '│'
        border_style = Style(fg=accent_color, bg=bg_color)
        set_char!(buf, area.x, y, border_char, border_style)
        
        # Draw text with padding
        text_style = Style(bg=bg_color, fg=fg_color)
        set_string!(buf, area.x + 2, y, full_text, text_style)
    end
    
    # Render scrollbar if needed
    if total_height > area.height
        scrollbar_area = Rect(right(area) - 1, area.y, 1, area.height)
        _render_scrollbar!(buf, scrollbar_area, m.queue_scroll_offset, total_height, area.height)
    end
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

