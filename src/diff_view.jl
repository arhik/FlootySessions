# ═══════════════════════════════════════════════════════════════════════
# GitHub-Style Diff View Component for Tachikoma TUI
#
# Provides a side-by-side (split) or unified diff view similar to GitHub's
# interface. Supports syntax highlighting, line numbers, and hunk navigation.
#
# Usage: include("path/to/diff_view.jl") in your TUI application
# ═══════════════════════════════════════════════════════════════════════

module DiffView

using Tachikoma
using DiffUtils

# ═══════════════════════════════════════════════════════════════════════
# Types and Constants
# ═══════════════════════════════════════════════════════════════════════

@enum DiffViewMode begin
    MODE_UNIFIED      # Single column view with +/- markers
    MODE_SPLIT        # Side-by-side view (left: old, right: new)
    MODE_INLINE       # Inline view (original with highlights)
end

@enum DiffLineType begin
    LINE_CONTEXT      # Unchanged line
    LINE_ADDED        # Added line (green)
    LINE_REMOVED      # Removed line (red)
    LINE_HUNK_HEADER  # @@ -x,y +a,b @@ header
    LINE_FILE_HEADER  # File header (--- / +++)
    LINE_EMPTY        # Empty placeholder for alignment
end

# Color constants (GitHub-style colors - foreground only, no backgrounds)
const DIFF_COLORS = Dict(
    # Line content colors
    :fg_context => ColorRGB(201, 209, 217),     # Light gray text
    :fg_added => ColorRGB(35, 197, 94),        # Bright green for additions
    :fg_removed => ColorRGB(248, 81, 73),      # Bright red for removals
    :fg_hunk => ColorRGB(139, 148, 158),        # Gray text for headers
    :fg_file_header => ColorRGB(139, 148, 158),
    :fg_line_number => ColorRGB(110, 118, 129), # Muted gray
    
    # Markers
    :marker_added => ColorRGB(35, 197, 94),    # + symbol
    :marker_removed => ColorRGB(248, 81, 73),  # - symbol
    :marker_context => Color256(240),          # space for context
    
    # Borders and separators
    :border_file => ColorRGB(48, 54, 61),
    :border_split => ColorRGB(48, 54, 61),
)

# ═══════════════════════════════════════════════════════════════════════
# Data Structures
# ═══════════════════════════════════════════════════════════════════════

"""
    DiffLine

Represents a single line in the diff with its metadata.
"""
struct DiffLine
    line_type::DiffLineType
    content::String
    old_line_num::Union{Int, Nothing}  # Line number in old file
    new_line_num::Union{Int, Nothing}  # Line number in new file
    hunk_offset::Int                    # Offset within current hunk
end

"""
    DiffHunk

Represents a hunk/section of changes in the diff.
"""
struct DiffHunk
    header::String                      # The @@ -x,y +a,b @@ line
    old_start::Int                      # Starting line in old file
    old_lines::Int                      # Number of lines in old
    new_start::Int                      # Starting line in new file
    new_lines::Int                      # Number of lines in new
    lines::Vector{DiffLine}             # Lines in this hunk
end

"""
    DiffFile

Represents a single file's diff with multiple hunks.
"""
struct DiffFile
    old_path::String
    new_path::String
    old_mode::Union{String, Nothing}
    new_mode::Union{String, Nothing}
    is_new::Bool
    is_deleted::Bool
    is_binary::Bool
    similarity::Union{Float64, Nothing}  # For rename/copy detection
    hunks::Vector{DiffHunk}
    stats::Dict{Symbol, Int}              # Lines added/removed counts
end

"""
    DiffViewState

Main state container for the diff view.
"""
mutable struct DiffViewState
    files::Vector{DiffFile}             # All files in the diff
    current_file_idx::Int               # Currently displayed file
    scroll_offset::Int                  # Vertical scroll position
    horizontal_scroll::Int              # Horizontal scroll (for long lines)
    view_mode::DiffViewMode             # Unified or split view
    show_line_numbers::Bool             # Show line numbers
    show_whitespace::Bool               # Highlight whitespace
    expand_all::Bool                    # Expand/collapse hunks
    collapsed_hunks::Set{Int}           # Set of collapsed hunk indices
    width::Int                          # Viewport width
    height::Int                         # Viewport height
    focused::Bool                       # Whether view has focus
    selected_line::Int                  # Currently selected line for navigation
    search_pattern::Union{String, Nothing}  # Active search
    search_results::Vector{Tuple{Int, Int}}   # (file_idx, line_idx) search results
    search_current::Int                 # Current search result index
end

function DiffViewState(; width=80, height=24, view_mode=MODE_SPLIT)
    DiffViewState(
        DiffFile[], 1, 0, 0, view_mode, true, false, true, Set{Int}(),
        width, height, false, 1, nothing, Vector{Tuple{Int, Int}}(), 0
    )
end

# ═══════════════════════════════════════════════════════════════════════
# Diff Parsing
# ═══════════════════════════════════════════════════════════════════════

"""
    parse_diff(text::String)::Vector{DiffFile}

Parse a unified diff text into structured DiffFile objects.
"""
function parse_diff(text::String)::Vector{DiffFile}
    files = DiffFile[]
    current_file = nothing
    current_hunk = nothing
    current_lines = DiffLine[]
    
    old_line = 0
    new_line = 0
    hunk_old_start = 0
    hunk_new_start = 0
    
    lines = split(text, '\n')
    i = 1
    
    while i <= length(lines)
        line = lines[i]
        
        # File header: --- old/path
        if startswith(line, "--- ")
            # Save previous file if exists
            if current_hunk !== nothing && !isempty(current_lines)
                current_hunk.lines = current_lines
                push!(current_file.hunks, current_hunk)
            end
            if current_file !== nothing && !isempty(current_file.hunks)
                update_file_stats!(current_file)
                push!(files, current_file)
            end
            
            old_path = line[5:end]
            # Remove timestamp if present
            if contains(old_path, '\t')
                old_path = split(old_path, '\t')[1]
            end
            old_path = strip(old_path)
            
            # Look ahead for +++ line
            i += 1
            new_path = ""
            if i <= length(lines) && startswith(lines[i], "+++ ")
                new_path = lines[i][5:end]
                if contains(new_path, '\t')
                    new_path = split(new_path, '\t')[1]
                end
                new_path = strip(new_path)
            end
            
            # Create new file
            current_file = DiffFile(
                old_path, new_path, nothing, nothing,
                old_path == "/dev/null", new_path == "/dev/null", false,
                nothing, DiffHunk[], Dict(:added => 0, :removed => 0)
            )
            current_hunk = nothing
            current_lines = DiffLine[]
            i += 1
            continue
        end
        
        # Hunk header: @@ -x,y +a,b @@
        if startswith(line, "@@ ")
            if current_hunk !== nothing && !isempty(current_lines)
                current_hunk.lines = current_lines
                push!(current_file.hunks, current_hunk)
            end
            
            # Parse hunk header
            # Format: @@ -old_start,old_count +new_start,new_count @@ optional text
            m = match(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)", line)
            if m !== nothing
                hunk_old_start = parse(Int, m.captures[1])
                hunk_old_lines = m.captures[2] === nothing ? 1 : parse(Int, m.captures[2])
                hunk_new_start = parse(Int, m.captures[3])
                hunk_new_lines = m.captures[4] === nothing ? 1 : parse(Int, m.captures[4])
                
                current_hunk = DiffHunk(
                    line, hunk_old_start, hunk_old_lines,
                    hunk_new_start, hunk_new_lines, DiffLine[]
                )
                old_line = hunk_old_start
                new_line = hunk_new_start
                
                push!(current_lines, DiffLine(
                    LINE_HUNK_HEADER, strip(m.captures[5]), nothing, nothing, 0
                ))
            end
            i += 1
            continue
        end
        
        # Diff content lines
        if current_hunk !== nothing
            if startswith(line, "+")
                content = length(line) > 1 ? line[2:end] : ""
                push!(current_lines, DiffLine(
                    LINE_ADDED, content, nothing, new_line, length(current_lines)
                ))
                new_line += 1
            elseif startswith(line, "-")
                content = length(line) > 1 ? line[2:end] : ""
                push!(current_lines, DiffLine(
                    LINE_REMOVED, content, old_line, nothing, length(current_lines)
                ))
                old_line += 1
            elseif startswith(line, " ") || line == ""
                # Context line (or empty with no marker)
                content = length(line) > 1 ? line[2:end] : ""
                push!(current_lines, DiffLine(
                    LINE_CONTEXT, content, old_line, new_line, length(current_lines)
                ))
                old_line += 1
                new_line += 1
            elseif startswith(line, "\\ No newline")
                # Handle "no newline at end of file" marker
                # Skip silently
            end
        end
        
        i += 1
    end
    
    # Save last hunk and file
    if current_hunk !== nothing && !isempty(current_lines)
        current_hunk.lines = current_lines
        push!(current_file.hunks, current_hunk)
    end
    if current_file !== nothing && !isempty(current_file.hunks)
        update_file_stats!(current_file)
        push!(files, current_file)
    end
    
    return files
end

"""
    update_file_stats!(file::DiffFile)

Calculate statistics for a diff file.
"""
function update_file_stats!(file::DiffFile)
    added = 0
    removed = 0
    for hunk in file.hunks
        for line in hunk.lines
            if line.line_type == LINE_ADDED
                added += 1
            elseif line.line_type == LINE_REMOVED
                removed += 1
            end
        end
    end
    file.stats[:added] = added
    file.stats[:removed] = removed
end

# ═══════════════════════════════════════════════════════════════════════
# Rendering
# ═══════════════════════════════════════════════════════════════════════

"""
    render_diff_view(buf::Buffer, state::DiffViewState, x::Int, y::Int)

Render the diff view to the buffer at position (x, y).
"""
function render_diff_view(buf::Buffer, state::DiffViewState, x::Int, y::Int)
    isempty(state.files) && return render_empty_diff(buf, state, x, y)
    
    file = state.files[state.current_file_idx]
    
    # Calculate layout
    header_height = 3  # File path + stats bar
    content_height = state.height - header_height
    
    # Render file header
    render_file_header(buf, file, state, x, y)
    
    # Render diff content
    if state.view_mode == MODE_SPLIT
        render_split_view(buf, file, state, x, y + header_height, content_height)
    else
        render_unified_view(buf, file, state, x, y + header_height, content_height)
    end
end

"""
    render_file_header(buf::Buffer, file::DiffFile, state::DiffViewState, x::Int, y::Int)

Render the file path header with change statistics.
"""
function render_file_header(buf::Buffer, file::DiffFile, state::DiffViewState, x::Int, y::Int)
    # File path bar
    header_style = Style(fg=DIFF_COLORS[:fg_file_header], bold=true)
    
    # Build header text
    if file.is_new
        path_display = "$(file.new_path) (new file)"
        icon = "+"
    elseif file.is_deleted
        path_display = "$(file.old_path) (deleted)"
        icon = "-"
    else
        path_display = file.new_path
        icon = "◆"
    end
    
    # Truncate if too long
    max_len = state.width - 20  # Leave room for stats
    if length(path_display) > max_len
        path_display = "..." * path_display[end-max_len+4:end]
    end
    
    header_text = " $icon $path_display "
    
    # Stats: +n -m
    added = file.stats[:added]
    removed = file.stats[:removed]
    stats_text = " +$added -$removed "
    
    # Full header line
    padding = state.width - length(header_text) - length(stats_text)
    full_header = header_text * repeat(" ", max(0, padding)) * stats_text
    
    set(buf, x, y, Cell(full_header, header_style))
    
    # Separator line
    sep_style = Style(fg=DIFF_COLORS[:border_file])
    separator = "─" ^ state.width
    set(buf, x, y + 1, Cell(separator, sep_style))
end

"""
    render_split_view(buf::Buffer, file::DiffFile, state::DiffViewState, x::Int, y::Int, height::Int)

Render side-by-side diff view.
"""
function render_split_view(buf::Buffer, file::DiffFile, state::DiffViewState, x::Int, y::Int, height::Int)
    # Calculate column widths
    gutter_width = state.show_line_numbers ? 6 : 0
    half_width = div(state.width - 1, 2)  # -1 for center divider
    col_width = half_width - 2 * gutter_width - 1
    
    center_x = x + half_width
    
    current_y = y
    lines_rendered = 0
    scroll_remaining = state.scroll_offset
    
    for hunk in file.hunks
        # Check if hunk is collapsed
        hunk_hash = hash(hunk)
        is_collapsed = hunk_hash in state.collapsed_hunks && !state.expand_all
        
        # Render hunk header
        if scroll_remaining > 0
            scroll_remaining -= 1
        elseif lines_rendered < height
            render_hunk_header(buf, hunk, state, x, current_y, half_width)
            lines_rendered += 1
            current_y += 1
        end
        
        if is_collapsed
            if scroll_remaining > 0
                scroll_remaining -= 1
            elseif lines_rendered < height
                collapsed_text = "  ⋮ ($(length(hunk.lines)) lines collapsed) ⋮"
                style = Style(fg=DIFF_COLORS[:fg_hunk], italic=true)
                set(buf, x + 2, current_y, Cell(collapsed_text, style))
                lines_rendered += 1
                current_y += 1
            end
            continue
        end
        
        # Render hunk lines side-by-side
        i = 1
        while i <= length(hunk.lines) && lines_rendered < height
            line = hunk.lines[i]
            
            if line.line_type == LINE_HUNK_HEADER
                i += 1
                continue
            end
            
            if scroll_remaining > 0
                scroll_remaining -= 1
                i += 1
                continue
            end
            
            # For split view, pair up removed and added lines
            if line.line_type == LINE_REMOVED
                # Look ahead for matching added line
                next_line = i < length(hunk.lines) ? hunk.lines[i + 1] : nothing
                if next_line !== nothing && next_line.line_type == LINE_ADDED
                    # Side-by-side: old | new
                    render_split_line_pair(buf, line, next_line, state, x, current_y, half_width, col_width)
                    i += 2
                else
                    # Removed line on left, blank on right
                    render_single_split_line(buf, line, nothing, state, x, current_y, half_width, col_width)
                    i += 1
                end
            elseif line.line_type == LINE_ADDED
                # Check if previous was removed (already handled above)
                if i > 1 && hunk.lines[i - 1].line_type == LINE_REMOVED
                    # Already rendered, skip
                    i += 1
                    continue
                end
                # Added line on right, blank on left
                render_single_split_line(buf, nothing, line, state, x, current_y, half_width, col_width)
                i += 1
            else
                # Context line - same on both sides
                render_split_line_pair(buf, line, line, state, x, current_y, half_width, col_width)
                i += 1
            end
            
            lines_rendered += 1
            current_y += 1
        end
    end
    
    # Fill remaining space with default
    while lines_rendered < height
        for cx in x:x+state.width-1
            set(buf, cx, current_y, Cell(" ", Style(fg=DIFF_COLORS[:fg_context])))
        end
        lines_rendered += 1
        current_y += 1
    end
end

"""
    render_split_line_pair(buf, old_line, new_line, state, x, y, half_width, col_width)

Render a pair of lines side-by-side in split view.
"""
function render_split_line_pair(buf::Buffer, old_line::DiffLine, new_line::DiffLine, 
                                state::DiffViewState, x::Int, y::Int, half_width::Int, col_width::Int)
    gutter_width = state.show_line_numbers ? 6 : 0
    
    # Determine styles based on line types
    old_style, new_style = get_split_styles(old_line, new_line)
    
    # Left column (old)
    old_num = old_line.old_line_num !== nothing ? lpad(string(old_line.old_line_num), 5) : "     "
    old_content = truncate_string(old_line.content, col_width)
    old_content_padded = rpad(old_content, col_width)
    
    # Right column (new)  
    new_num = new_line.new_line_num !== nothing ? lpad(string(new_line.new_line_num), 5) : "     "
    new_content = truncate_string(new_line.content, col_width)
    new_content_padded = rpad(new_content, col_width)
    
    # Render with appropriate markers
    old_marker = old_line.line_type == LINE_REMOVED ? "-" : 
                 old_line.line_type == LINE_CONTEXT ? " " : " "
    new_marker = new_line.line_type == LINE_ADDED ? "+" :
                 new_line.line_type == LINE_CONTEXT ? " " : " "
    
    # Build left line
    num_style = Style(fg=DIFF_COLORS[:fg_line_number])
    if state.show_line_numbers
        # Line number | marker | content
        left_text = "$old_num $old_marker$old_content_padded"
        set(buf, x, y, Cell(left_text[1:gutter_width], num_style))
        set(buf, x + gutter_width, y, Cell(old_marker * old_content_padded, old_style))
    else
        set(buf, x, y, Cell(old_marker * old_content_padded, old_style))
    end
    
    # Divider
    div_x = x + half_width
    div_style = Style(fg=DIFF_COLORS[:border_split])
    set(buf, div_x, y, Cell("│", div_style))
    
    # Build right line
    if state.show_line_numbers
        right_text = "$new_num $new_marker$new_content_padded"
        set(buf, div_x + 1, y, Cell(right_text[1:gutter_width], num_style))
        set(buf, div_x + 1 + gutter_width, y, Cell(new_marker * new_content_padded, new_style))
    else
        set(buf, div_x + 1, y, Cell(new_marker * new_content_padded, new_style))
    end
end

"""
    render_single_split_line(buf, old_line, new_line, state, x, y, half_width, col_width)

Render a line with blank on one side (for unmatched add/remove).
"""
function render_single_split_line(buf::Buffer, old_line::Union{DiffLine, Nothing}, 
                                  new_line::Union{DiffLine, Nothing}, state::DiffViewState,
                                  x::Int, y::Int, half_width::Int, col_width::Int)
    gutter_width = state.show_line_numbers ? 6 : 0
    
    if old_line !== nothing
        # Removed line on left
        style = Style(fg=DIFF_COLORS[:fg_removed])
        num = old_line.old_line_num !== nothing ? lpad(string(old_line.old_line_num), 5) : "     "
        content = truncate_string(old_line.content, col_width)
        
        if state.show_line_numbers
            num_style = Style(fg=DIFF_COLORS[:fg_line_number])
            set(buf, x, y, Cell(num * " ", num_style))
            set(buf, x + gutter_width, y, Cell("-" * content, style))
        else
            set(buf, x, y, Cell("-" * content, style))
        end
        
        # Blank right side
        blank = " " ^ (half_width - 1)
        set(buf, x + half_width, y, Cell("│", Style(fg=DIFF_COLORS[:border_split])))
        set(buf, x + half_width + 1, y, Cell(blank, Style(fg=DIFF_COLORS[:fg_context])))
    else
        # Added line on right
        style = Style(fg=DIFF_COLORS[:fg_added])
        num = new_line.new_line_num !== nothing ? lpad(string(new_line.new_line_num), 5) : "     "
        content = truncate_string(new_line.content, col_width)
        
        # Blank left side
        blank = " " ^ (half_width - 1)
        set(buf, x, y, Cell(blank, Style(fg=DIFF_COLORS[:fg_context])))
        set(buf, x + half_width, y, Cell("│", Style(fg=DIFF_COLORS[:border_split])))
        
        if state.show_line_numbers
            num_style = Style(fg=DIFF_COLORS[:fg_line_number])
            set(buf, x + half_width + 1, y, Cell(num * " ", num_style))
            set(buf, x + half_width + 1 + gutter_width, y, Cell("+" * content, style))
        else
            set(buf, x + half_width + 1, y, Cell("+" * content, style))
        end
    end
end

"""
    render_unified_view(buf, file, state, x, y, height)

Render unified (single column) diff view with +/- markers.
"""
function render_unified_view(buf::Buffer, file::DiffFile, state::DiffViewState, x::Int, y::Int, height::Int)
    gutter_width = state.show_line_numbers ? 12 : 0  # Space for two line numbers
    content_width = state.width - gutter_width - 1  # -1 for marker
    
    current_y = y
    lines_rendered = 0
    scroll_remaining = state.scroll_offset
    
    for hunk in file.hunks
        hunk_hash = hash(hunk)
        is_collapsed = hunk_hash in state.collapsed_hunks && !state.expand_all
        
        # Render hunk header
        if scroll_remaining > 0
            scroll_remaining -= 1
        elseif lines_rendered < height
            render_hunk_header(buf, hunk, state, x, current_y, state.width)
            lines_rendered += 1
            current_y += 1
        end
        
        if is_collapsed
            if scroll_remaining > 0
                scroll_remaining -= 1
            elseif lines_rendered < height
                collapsed_text = "  ⋮ ($(length(hunk.lines)) lines collapsed) ⋮"
                style = Style(fg=DIFF_COLORS[:fg_hunk], italic=true)
                set(buf, x + 2, current_y, Cell(collapsed_text, style))
                lines_rendered += 1
                current_y += 1
            end
            continue
        end
        
        # Render hunk lines
        for line in hunk.lines
            line.line_type == LINE_HUNK_HEADER && continue
            
            if scroll_remaining > 0
                scroll_remaining -= 1
                continue
            end
            
            lines_rendered >= height && break
            
            render_unified_line(buf, line, state, x, current_y, content_width)
            lines_rendered += 1
            current_y += 1
        end
    end
    
    # Fill remaining space
    while lines_rendered < height
        for cx in x:x+state.width-1
            set(buf, cx, current_y, Cell(" ", Style(fg=DIFF_COLORS[:fg_context])))
        end
        lines_rendered += 1
        current_y += 1
    end
end

"""
    render_unified_line(buf, line, state, x, y, content_width)

Render a single line in unified mode.
"""
function render_unified_line(buf::Buffer, line::DiffLine, state::DiffViewState, x::Int, y::Int, content_width::Int)
    style = get_line_style(line.line_type)
    marker = get_line_marker(line.line_type)
    content = truncate_string(line.content, content_width)
    
    # Build the line with line numbers if enabled
    if state.show_line_numbers
        old_num = line.old_line_num !== nothing ? lpad(string(line.old_line_num), 5) : ""
        new_num = line.new_line_num !== nothing ? lpad(string(line.new_line_num), 5) : ""
        num_style = Style(fg=DIFF_COLORS[:fg_line_number])
        num_text = old_num * new_num * " "
        
        set(buf, x, y, Cell(num_text, num_style))
        set(buf, x + 11, y, Cell(marker * content, style))
    else
        set(buf, x, y, Cell(marker * content, style))
    end
end

"""
    render_hunk_header(buf, hunk, state, x, y, width)
"""
function render_hunk_header(buf::Buffer, hunk::DiffHunk, state::DiffViewState, x::Int, y::Int, width::Int)
    style = Style(fg=DIFF_COLORS[:fg_hunk], bold=true)
    
    # Format: @@ -old_start,old_lines +new_start,new_lines @@
    header = "@@ -$(hunk.old_start),$(hunk.old_lines) +$(hunk.new_start),$(hunk.new_lines) @@"
    text = rpad(header, width)
    
    set(buf, x, y, Cell(text, style))
end

"""
    render_empty_diff(buf, state, x, y)
"""
function render_empty_diff(buf::Buffer, state::DiffViewState, x::Int, y::Int)
    text = " No diff to display "
    style = Style(fg=Color256(245), italic=true)
    cx = x + div(state.width - length(text), 2)
    cy = y + div(state.height, 2)
    set(buf, cx, cy, Cell(text, style))
end

# ═══════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════

"""
    get_line_style(line_type::DiffLineType)::Style

Get the appropriate style for a line type.
"""
function get_line_style(line_type::DiffLineType)::Style
    if line_type == LINE_ADDED
        Style(fg=DIFF_COLORS[:fg_added])
    elseif line_type == LINE_REMOVED
        Style(fg=DIFF_COLORS[:fg_removed])
    elseif line_type == LINE_HUNK_HEADER
        Style(fg=DIFF_COLORS[:fg_hunk], bold=true)
    elseif line_type == LINE_FILE_HEADER
        Style(fg=DIFF_COLORS[:fg_file_header], bold=true)
    else
        Style(fg=DIFF_COLORS[:fg_context])
    end
end

"""
    get_split_styles(old_line, new_line)::Tuple{Style, Style}

Get styles for side-by-side display.
"""
function get_split_styles(old_line::DiffLine, new_line::DiffLine)::Tuple{Style, Style}
    old_style = if old_line.line_type == LINE_REMOVED
        Style(fg=DIFF_COLORS[:fg_removed])
    elseif old_line.line_type == LINE_CONTEXT
        Style(fg=DIFF_COLORS[:fg_context])
    else
        Style(fg=DIFF_COLORS[:fg_context])
    end
    
    new_style = if new_line.line_type == LINE_ADDED
        Style(fg=DIFF_COLORS[:fg_added])
    elseif new_line.line_type == LINE_CONTEXT
        Style(fg=DIFF_COLORS[:fg_context])
    else
        Style(fg=DIFF_COLORS[:fg_context])
    end
    
    return (old_style, new_style)
end

"""
    get_line_marker(line_type::DiffLineType)::String

Get the marker character for a line type.
"""
function get_line_marker(line_type::DiffLineType)::String
    if line_type == LINE_ADDED
        "+"
    elseif line_type == LINE_REMOVED
        "-"
    else
        " "
    end
end

"""
    truncate_string(str::String, max_len::Int)::String

Truncate string to fit in given width.
"""
function truncate_string(str::String, max_len::Int)::String
    if length(str) <= max_len
        return str
    end
    return str[1:max_len-3] * "..."
end

# ═══════════════════════════════════════════════════════════════════════
# Navigation and Interaction
# ═══════════════════════════════════════════════════════════════════════

"""
    move_cursor!(state::DiffViewState, delta::Int)

Move the cursor by delta lines.
"""
function move_cursor!(state::DiffViewState, delta::Int)
    # Calculate total lines
    total_lines = count_lines(state)
    
    new_pos = max(1, min(total_lines, state.selected_line + delta))
    state.selected_line = new_pos
    
    # Adjust scroll if necessary
    visible_start = state.scroll_offset + 1
    visible_end = state.scroll_offset + state.height - 3  # -3 for header
    
    if new_pos < visible_start
        state.scroll_offset = max(0, new_pos - 1)
    elseif new_pos > visible_end
        state.scroll_offset = min(total_lines - state.height + 3, new_pos - state.height + 3)
    end
end

"""
    count_lines(state::DiffViewState)::Int

Count total displayable lines.
"""
function count_lines(state::DiffViewState)::Int
    isempty(state.files) && return 0
    
    file = state.files[state.current_file_idx]
    total = 0
    
    for hunk in file.hunks
        total += 1  # Hunk header
        hunk_hash = hash(hunk)
        if hunk_hash in state.collapsed_hunks && !state.expand_all
            total += 1  # Collapsed marker
        else
            for line in hunk.lines
                line.line_type == LINE_HUNK_HEADER || (total += 1)
            end
        end
    end
    
    return total
end

"""
    next_file!(state::DiffViewState)
"""
function next_file!(state::DiffViewState)
    if state.current_file_idx < length(state.files)
        state.current_file_idx += 1
        state.scroll_offset = 0
        state.selected_line = 1
    end
end

"""
    prev_file!(state::DiffViewState)
"""
function prev_file!(state::DiffViewState)
    if state.current_file_idx > 1
        state.current_file_idx -= 1
        state.scroll_offset = 0
        state.selected_line = 1
    end
end

"""
    toggle_hunk!(state::DiffViewState, hunk_idx::Int)

Toggle collapse/expand for a hunk.
"""
function toggle_hunk!(state::DiffViewState, hunk_idx::Int)
    hunk_hash = hash(state.files[state.current_file_idx].hunks[hunk_idx])
    if hunk_hash in state.collapsed_hunks
        delete!(state.collapsed_hunks, hunk_hash)
    else
        push!(state.collapsed_hunks, hunk_hash)
    end
end

"""
    toggle_view_mode!(state::DiffViewState)
"""
function toggle_view_mode!(state::DiffViewState)
    if state.view_mode == MODE_SPLIT
        state.view_mode = MODE_UNIFIED
    else
        state.view_mode = MODE_SPLIT
    end
end

# ═══════════════════════════════════════════════════════════════════════
# Search Functionality
# ═══════════════════════════════════════════════════════════════════════

"""
    search!(state::DiffViewState, pattern::String)

Search for pattern in the diff.
"""
function search!(state::DiffViewState, pattern::String)
    state.search_pattern = pattern
    empty!(state.search_results)
    
    isempty(pattern) && return
    
    for (file_idx, file) in enumerate(state.files)
        line_offset = 0
        for hunk in file.hunks
            for line in hunk.lines
                line_offset += 1
                if occursin(pattern, line.content)
                    push!(state.search_results, (file_idx, line_offset))
                end
            end
        end
    end
    
    state.search_current = isempty(state.search_results) ? 0 : 1
end

"""
    next_search_result!(state::DiffViewState)
"""
function next_search_result!(state::DiffViewState)
    isempty(state.search_results) && return
    state.search_current = (state.search_current % length(state.search_results)) + 1
    result = state.search_results[state.search_current]
    state.current_file_idx = result[1]
    state.selected_line = result[2]
    move_cursor!(state, 0)  # Adjust scroll
end

"""
    prev_search_result!(state::DiffViewState)
"""
function prev_search_result!(state::DiffViewState)
    isempty(state.search_results) && return
    state.search_current = state.search_current <= 1 ? length(state.search_results) : state.search_current - 1
    result = state.search_results[state.search_current]
    state.current_file_idx = result[1]
    state.selected_line = result[2]
    move_cursor!(state, 0)  # Adjust scroll
end

# ═══════════════════════════════════════════════════════════════════════
# High-Level API
# ═══════════════════════════════════════════════════════════════════════

"""
    DiffViewer

Widget for displaying git diffs in GitHub style.

# Example Usage:
```julia
using Tachikoma
using FlootySessions.DiffView

# Create viewer
viewer = DiffViewer(80, 24)

# Load a diff
load_diff!(viewer, `
--- a/src/main.jl
+++ b/src/main.jl
@@ -10,7 +10,7 @@ function hello()
     println("Hello, World!")
 end
 
-function goodbye()
+function farewell()
     println("Goodbye!")
 end
`)

# Render as part of your app
render_widget(app.buffer, viewer, 0, 0, 24)
```
"""
mutable struct DiffViewer
    state::DiffViewState
    
    function DiffViewer(width::Int=80, height::Int=24; view_mode=MODE_SPLIT)
        new(DiffViewState(; width=width, height=height, view_mode=view_mode))
    end
end

"""
    load_diff!(viewer::DiffViewer, diff_text::String)

Load a diff into the viewer.
"""
function load_diff!(viewer::DiffViewer, diff_text::String)
    viewer.state.files = parse_diff(diff_text)
    viewer.state.current_file_idx = isempty(viewer.state.files) ? 0 : 1
    viewer.state.scroll_offset = 0
    viewer.state.selected_line = 1
    empty!(viewer.state.collapsed_hunks)
end

"""
    load_from_git!(viewer::DiffViewer, repo_path::String=".", ref::String="HEAD")

Load diff from git repository.
"""
function load_from_git!(viewer::DiffViewer, repo_path::String=".", ref::String="HEAD")
    try
        # Build git command using Cmd constructor to avoid parsing issues
        git_cmd = ["git", "-C", repo_path, "diff"]
        if ref != "HEAD"
            push!(git_cmd, "$(ref)~1..$(ref)")
        end
        diff_text = read(Cmd(git_cmd), String)
        load_diff!(viewer, diff_text)
    catch e
        load_diff!(viewer, "---\n+++\n@@ Error loading git diff: $(sprint(showerror, e)) @@")
    end
end

"""
    render_widget(buf::Buffer, viewer::DiffViewer, x::Int, y::Int, max_y::Int)

Render the diff viewer widget (compatible with Tachikoma).
"""
function render_widget(buf::Buffer, viewer::DiffViewer, x::Int, y::Int, max_y::Int)
    viewer.state.height = max_y - y
    render_diff_view(buf, viewer.state, x, y)
end

# Convenience exports
export DiffViewer, DiffViewMode, MODE_SPLIT, MODE_UNIFIED, MODE_INLINE
export load_diff!, load_from_git!, next_file!, prev_file!, toggle_view_mode!
export move_cursor!, search!, next_search_result!, prev_search_result!

end # module DiffView