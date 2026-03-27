# ═══════════════════════════════════════════════════════════════════════
# GitHub-Style Diff View Component for Tachikoma TUI
#
# Features:
# - Split and unified view modes
# - Line numbers
# - Word wrap for long lines
# - Background colors like GitHub (no +/- markers)
# ═══════════════════════════════════════════════════════════════════════

module DiffView

using Tachikoma
using DiffUtils

# Import internal functions that aren't exported
import Tachikoma: set!, set_char!, set_string!

@enum DiffViewMode MODE_UNIFIED MODE_SPLIT MODE_INLINE

@enum DiffLineType LINE_CONTEXT LINE_ADDED LINE_REMOVED LINE_HUNK_HEADER LINE_FILE_HEADER LINE_EMPTY

# Darker background colors for changes - white text, no bg for context/hunk/empty
const DIFF_COLORS = Dict(
    :fg_context => ColorRGB(150, 150, 150),     # GREY text for unchanged lines
    :fg_added => ColorRGB(255, 255, 255),      # White text
    :fg_removed => ColorRGB(255, 255, 255),     # White text
    :fg_hunk => ColorRGB(88, 96, 105),
    :fg_file_header => ColorRGB(88, 96, 105),
    :fg_line_number => ColorRGB(150, 155, 160),
    :border_file => ColorRGB(200, 205, 210),
    :border_split => ColorRGB(200, 205, 210),
    # Dark colors, 40 point difference, darker overall
    # ADDED: shifted darker, 50 line numbers, 10 content = 40 difference
    :bg_added => ColorRGB(50, 85, 40),        # Darker green for line numbers
    :bg_added_content => ColorRGB(10, 45, 5),    # Much darker green for code
    # REMOVED: shifted darker, 100 line numbers, 60 content = 40 difference
    :bg_removed => ColorRGB(100, 45, 45),       # Dark red for line numbers
    :bg_removed_content => ColorRGB(60, 25, 25),  # Much darker red for code
    :bg_context => ColorRGB(255, 255, 255),
    :bg_hunk => ColorRGB(255, 255, 255),
)

# Style for file header (no background)
get_file_header_style() = Style(fg=DIFF_COLORS[:fg_file_header], bold=true)

mutable struct DiffLine
    line_type::DiffLineType
    content::String
    old_line_num::Union{Int, Nothing}
    new_line_num::Union{Int, Nothing}
end

mutable struct DiffHunk
    header::String
    old_start::Int
    old_lines::Int
    new_start::Int
    new_lines::Int
    lines::Vector{DiffLine}
end

mutable struct DiffFile
    old_path::String
    new_path::String
    is_new::Bool
    is_deleted::Bool
    hunks::Vector{DiffHunk}
    stats::Dict{Symbol, Int}
end

mutable struct DiffViewState
    files::Vector{DiffFile}
    current_file_idx::Int
    scroll_offset::Int
    view_mode::DiffViewMode
    show_line_numbers::Bool
    word_wrap::Bool  # NEW: enable word wrap
    collapsed_hunks::Set{Int}
    width::Int
    height::Int
    selected_line::Int
end

function DiffViewState(; width=80, height=24, view_mode=MODE_SPLIT, word_wrap=true)
    DiffViewState(DiffFile[], 1, 0, view_mode, true, word_wrap, Set{Int}(), width, height, 1)
end

mutable struct DiffViewer
    state::DiffViewState
    DiffViewer(w=80, h=24; view_mode=MODE_SPLIT, word_wrap=true) = new(DiffViewState(; width=w, height=h, view_mode=view_mode, word_wrap=word_wrap))
end

function parse_diff(text::String)::Vector{DiffFile}
    files = DiffFile[]
    current_file = nothing
    current_hunk = nothing
    current_lines = DiffLine[]
    old_line, new_line = 0, 0
    old_path_tmp = ""
    new_path_tmp = ""
    
    for line in split(text, '\n')
        if startswith(line, "--- ")
            # Save previous file if exists
            if current_file !== nothing && !isempty(current_file.hunks)
                push!(files, current_file)
            end
            # Store old path temporarily
            old_path_tmp = strip(line[5:end])
            old_path_tmp = contains(old_path_tmp, '\t') ? split(old_path_tmp, '\t')[1] : old_path_tmp
            current_file = nothing  # Will create after we see +++
            current_hunk = nothing
            current_lines = DiffLine[]
        elseif startswith(line, "+++ ")
            new_path_tmp = strip(line[5:end])
            new_path_tmp = contains(new_path_tmp, '\t') ? split(new_path_tmp, '\t')[1] : new_path_tmp
            # Now create the file with both paths
            current_file = DiffFile(
                old_path_tmp,
                new_path_tmp,
                new_path_tmp == "/dev/null",
                old_path_tmp == "/dev/null",
                DiffHunk[],
                Dict(:added=>0, :removed=>0)
            )
        elseif startswith(line, "@@ ")
            # Save previous hunk's lines before starting new hunk
            if current_hunk !== nothing && !isempty(current_lines)
                current_hunk.lines = current_lines
                push!(current_file.hunks, current_hunk)
                current_lines = DiffLine[]
            end
            m = match(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)", line)
            if m !== nothing
                old_s = parse(Int, m.captures[1])
                old_c = m.captures[2] === nothing ? 1 : parse(Int, m.captures[2])
                new_s = parse(Int, m.captures[3])
                new_c = m.captures[4] === nothing ? 1 : parse(Int, m.captures[4])
                current_hunk = DiffHunk(line, old_s, old_c, new_s, new_c, DiffLine[])
                old_line, new_line = old_s, new_s
                push!(current_lines, DiffLine(LINE_HUNK_HEADER, strip(m.captures[5]), nothing, nothing))
            end
        elseif startswith(line, "+") && current_hunk !== nothing
            content = length(line) > 1 ? line[2:end] : ""
            push!(current_lines, DiffLine(LINE_ADDED, content, nothing, new_line))
            new_line += 1
        elseif startswith(line, "-") && current_hunk !== nothing
            content = length(line) > 1 ? line[2:end] : ""
            push!(current_lines, DiffLine(LINE_REMOVED, content, old_line, nothing))
            old_line += 1
        elseif startswith(line, " ") && current_hunk !== nothing
            content = length(line) > 1 ? line[2:end] : ""
            push!(current_lines, DiffLine(LINE_CONTEXT, content, old_line, new_line))
            old_line += 1
            new_line += 1
        end
    end
    
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

function update_file_stats!(file::DiffFile)
    added = removed = 0
    for h in file.hunks, l in h.lines
        l.line_type == LINE_ADDED && (added += 1)
        l.line_type == LINE_REMOVED && (removed += 1)
    end
    file.stats[:added] = added
    file.stats[:removed] = removed
end

truncate_string(s, m) = length(s) <= m ? s : s[1:m-3] * "..."

# Word wrap: split content into lines that fit within width
function wrap_content(content::String, width::Int)::Vector{String}
    width <= 0 && return String[]
    lines = String[]
    remaining = content
    while !isempty(remaining)
        if length(remaining) <= width
            push!(lines, remaining)
            break
        end
        # Find break point (prefer at space)
        break_pos = width
        for i in width:-1:1
            if remaining[i] == ' '
                break_pos = i
                break
            end
        end
        # If no space found, hard break at width
        push!(lines, remaining[1:break_pos])
        remaining = remaining[break_pos+1:end]
        # Strip leading space for wrapped continuation
        remaining = lstrip(remaining)
    end
    isempty(lines) && push!(lines, "")
    return lines
end

# Style for line numbers (brighter) - white text forced
get_gutter_style(t) = t == LINE_ADDED ? Style(fg=ColorRGB(255,255,255), bg=DIFF_COLORS[:bg_added]) :
                      t == LINE_REMOVED ? Style(fg=ColorRGB(255,255,255), bg=DIFF_COLORS[:bg_removed]) :
                      Style(fg=DIFF_COLORS[:fg_context])

# Style for content (darker) - white text
get_line_style(t) = t == LINE_ADDED ? Style(fg=ColorRGB(255,255,255), bg=DIFF_COLORS[:bg_added_content]) :
                   t == LINE_REMOVED ? Style(fg=ColorRGB(255,255,255), bg=DIFF_COLORS[:bg_removed_content]) :
                   Style(fg=DIFF_COLORS[:fg_context])

# Same style for wrapped lines
get_wrapped_style(t) = get_line_style(t)

function render_file_header(buf::Buffer, file::DiffFile, state::DiffViewState, x::Int, y::Int)
    icon = file.is_new ? '+' : file.is_deleted ? '-' : '◆'
    path = file.is_new ? "$(file.new_path) (new)" : file.is_deleted ? "$(file.old_path) (deleted)" : file.new_path
    max_len = state.width - 20
    length(path) > max_len && (path = "..." * path[end-max_len+4:end])
    
    header = " $icon $path "
    stats = " +$(file.stats[:added]) -$(file.stats[:removed]) "
    full = header * repeat(" ", max(0, state.width - length(header) - length(stats))) * stats
    
    set_string!(buf, x, y, full, Style(fg=DIFF_COLORS[:fg_file_header], bold=true))
    set_string!(buf, x, y + 1, "─" ^ state.width, Style(fg=DIFF_COLORS[:border_file]))
end

function render_split_view(buf::Buffer, file::DiffFile, state::DiffViewState, x::Int, y::Int, height::Int)
    # Split view: [space][5-num][space] bright (7) + [space] dark (1) = 8
    gutter = state.show_line_numbers ? 8 : 0  # 7 bright + 1 dark gap
    half = div(state.width, 2)
    col_w = half - gutter - 1  # gutter + divider
    
    cy = y
    lines = 0
    skip = state.scroll_offset
    
    for hunk in file.hunks
        skip > 0 ? (skip -= 1; continue) : lines >= height && break
        render_hunk_header(buf, hunk, state, x, cy, half * 2)  # Full width
        cy += 1
        lines += 1
        
        for i in 1:length(hunk.lines)
            line = hunk.lines[i]
            line.line_type == LINE_HUNK_HEADER && continue
            skip > 0 ? (skip -= 1; continue) : lines >= height && break
            
            if line.line_type == LINE_REMOVED && i < length(hunk.lines) && hunk.lines[i+1].line_type == LINE_ADDED
                # Modified line: show old and new side by side with matching row heights
                old_l = line
                new_l = hunk.lines[i+1]
                rows = render_split_pair_fullspan(buf, old_l, new_l, state, x, cy, half, col_w, gutter, height - lines)
                cy += rows
                lines += rows
            elseif line.line_type == LINE_ADDED && i > 1 && hunk.lines[i-1].line_type == LINE_REMOVED
                # Skip - already rendered as part of pair above
                continue
            else
                # Single side change - need empty line for opposite side
                if line.line_type == LINE_ADDED
                    # Added line: empty on old side, content on new side
                    empty_line = DiffLine(LINE_EMPTY, "", nothing, nothing)
                    rows = render_split_pair_fullspan(buf, empty_line, line, state, x, cy, half, col_w, gutter, height - lines)
                elseif line.line_type == LINE_REMOVED
                    # Removed line: content on old side, empty on new side  
                    empty_line = DiffLine(LINE_EMPTY, "", nothing, nothing)
                    rows = render_split_pair_fullspan(buf, line, empty_line, state, x, cy, half, col_w, gutter, height - lines)
                else
                    # Context: same on both sides
                    rows = render_split_pair_fullspan(buf, line, line, state, x, cy, half, col_w, gutter, height - lines)
                end
                cy += rows
                lines += rows
            end
        end
    end
end

# Full-span split rendering - uses proper half widths
function render_split_pair_fullspan(buf::Buffer, old_l::DiffLine, new_l::DiffLine, state::DiffViewState, x::Int, y::Int, half::Int, col_w::Int, gutter::Int, max_rows::Int)
    # Get wrapped content for both sides
    old_wrapped = state.word_wrap ? wrap_content(old_l.content, col_w) : [truncate_string(old_l.content, col_w)]
    new_wrapped = state.word_wrap ? wrap_content(new_l.content, col_w) : [truncate_string(new_l.content, col_w)]
    
    rows = max(length(old_wrapped), length(new_wrapped))
    rows = min(rows, max_rows)  # Don't exceed available height
    
    # Line numbers (old on left side only when showing line numbers)
    old_n = old_l.old_line_num !== nothing ? lpad(string(old_l.old_line_num), 5) : "     "
    new_n = new_l.new_line_num !== nothing ? lpad(string(new_l.new_line_num), 5) : "     "
    
    for r in 1:rows
        row_y = y + r - 1
        
        # Left side: old content with old line number in gutter (if first row)
        old_txt = r <= length(old_wrapped) ? rpad(old_wrapped[r], col_w) : " " ^ col_w
        old_style = r == 1 ? get_line_style(old_l.line_type) : get_wrapped_style(old_l.line_type)
        
        if state.show_line_numbers
            # Format: [space][line_num][space] bright gutter + [space] dark gap + code
            ln_str = r == 1 ? " $old_n " : "       "  # 1 space + 5 num + 1 space = 7 chars bright
            set_string!(buf, x, row_y, ln_str, get_gutter_style(old_l.line_type))
            set_char!(buf, x + 7, row_y, ' ', old_style)  # 1 dark space gap
            set_string!(buf, x + 8, row_y, old_txt, old_style)
        else
            set_string!(buf, x, row_y, old_txt, old_style)
        end
        
        # Center divider
        set_char!(buf, x + half - 1, row_y, '│', Style(fg=DIFF_COLORS[:border_split]))
        
        # Right side: new content - this spans from half to end of width
        new_txt = r <= length(new_wrapped) ? rpad(new_wrapped[r], col_w) : " " ^ col_w
        new_style = r == 1 ? get_line_style(new_l.line_type) : get_wrapped_style(new_l.line_type)
        
        if state.show_line_numbers
            # Format: [space][line_num][space] bright gutter + [space] dark gap + code
            ln_str = r == 1 ? " $new_n " : "       "  # 1 space + 5 num + 1 space = 7 chars bright
            set_string!(buf, x + half, row_y, ln_str, get_gutter_style(new_l.line_type))
            set_char!(buf, x + half + 7, row_y, ' ', new_style)  # 1 dark space gap
            set_string!(buf, x + half + 8, row_y, new_txt, new_style)
        else
            set_string!(buf, x + half, row_y, new_txt, new_style)
        end
    end
    
    return rows
end

# OLD render_split_pair_wrapped - kept for reference but no longer used
function render_split_pair_wrapped(buf::Buffer, old_l::DiffLine, new_l::DiffLine, state::DiffViewState, x::Int, y::Int, half::Int, col_w::Int, max_rows::Int)
    gutter = state.show_line_numbers ? 6 : 0
    
    # Get wrapped content for both sides
    old_wrapped = state.word_wrap ? wrap_content(old_l.content, col_w) : [truncate_string(old_l.content, col_w)]
    new_wrapped = state.word_wrap ? wrap_content(new_l.content, col_w) : [truncate_string(new_l.content, col_w)]
    
    rows = max(length(old_wrapped), length(new_wrapped))
    rows = min(rows, max_rows)  # Don't exceed available height
    
    # Render with line number on first row only
    old_n = old_l.old_line_num !== nothing ? lpad(string(old_l.old_line_num), 5) : "     "
    new_n = new_l.new_line_num !== nothing ? lpad(string(new_l.new_line_num), 5) : "     "
    
    for r in 1:rows
        row_y = y + r - 1
        
        # Old side content
        old_txt = r <= length(old_wrapped) ? rpad(old_wrapped[r], col_w) : " " ^ col_w
        old_style = r == 1 ? get_line_style(old_l.line_type) : get_wrapped_style(old_l.line_type)
        if state.show_line_numbers
            set_string!(buf, x, row_y, r == 1 ? "$old_n " : "      ", Style(fg=DIFF_COLORS[:fg_line_number]))
            set_string!(buf, x + gutter, row_y, old_txt, old_style)
        else
            set_string!(buf, x, row_y, old_txt, old_style)
        end
        
        # Divider
        set_char!(buf, x + half, row_y, '│', Style(fg=DIFF_COLORS[:border_split]))
        
        # New side content  
        new_txt = r <= length(new_wrapped) ? rpad(new_wrapped[r], col_w) : " " ^ col_w
        new_style = r == 1 ? get_line_style(new_l.line_type) : get_wrapped_style(new_l.line_type)
        if state.show_line_numbers
            set_string!(buf, x + half + 1, row_y, r == 1 ? "$new_n " : "      ", Style(fg=DIFF_COLORS[:fg_line_number]))
            set_string!(buf, x + half + 1 + gutter, row_y, new_txt, new_style)
        else
            set_string!(buf, x + half + 1, row_y, new_txt, new_style)
        end
    end
    
    return rows
end

function render_unified_view(buf::Buffer, file::DiffFile, state::DiffViewState, x::Int, y::Int, height::Int)
    gutter = state.show_line_numbers ? 16 : 0  # 7 + 1 gap + 7 + 1 gap
    content_w = state.width - gutter - 1
    
    cy = y
    lines = 0
    skip = state.scroll_offset
    
    for hunk in file.hunks
        skip > 0 ? (skip -= 1; continue) : lines >= height && break
        render_hunk_header(buf, hunk, state, x, cy, state.width)
        cy += 1
        lines += 1
        
        for line in hunk.lines
            line.line_type == LINE_HUNK_HEADER && continue
            skip > 0 ? (skip -= 1; continue) : lines >= height && break
            
            # Word wrap support for unified view
            wrapped = state.word_wrap ? wrap_content(line.content, content_w) : [truncate_string(line.content, content_w)]
            
            first_row = true
            for content_line in wrapped
                lines >= height && break
                
                style = first_row ? get_line_style(line.line_type) : get_wrapped_style(line.line_type)
                
                if state.show_line_numbers
                    old_n = line.old_line_num !== nothing ? lpad(string(line.old_line_num), 5) : "     "
                    new_n = line.new_line_num !== nothing ? lpad(string(line.new_line_num), 5) : "     "
                    # Format: [space][old_num][space] bright + [space] dark gap + [space][new_num][space] bright + [space] dark + code
                    set_string!(buf, x, cy, " $old_n ", get_gutter_style(line.line_type))  # 7 chars bright
                    set_char!(buf, x + 7, cy, ' ', style)  # dark gap
                    set_string!(buf, x + 8, cy, " $new_n ", get_gutter_style(line.line_type))  # 7 chars bright
                    set_char!(buf, x + 15, cy, ' ', style)  # dark gap before code
                    set_string!(buf, x + 16, cy, rpad(content_line, content_w), style)
                else
                    set_string!(buf, x, cy, rpad(content_line, content_w), style)
                end
                
                cy += 1
                lines += 1
                first_row = false
            end
        end
    end
end

function render_hunk_header(buf::Buffer, hunk::DiffHunk, state::DiffViewState, x::Int, y::Int, w::Int)
    txt = "@@ -$(hunk.old_start),$(hunk.old_lines) +$(hunk.new_start),$(hunk.new_lines) @@"
    set_string!(buf, x, y, rpad(txt, w), Style(fg=DIFF_COLORS[:fg_hunk], bold=true))
end

function render_empty_diff(buf::Buffer, state::DiffViewState, x::Int, y::Int)
    txt = "No diff to display"
    cx = x + div(state.width - length(txt), 2)
    cy = y + div(state.height, 2)
    set_string!(buf, cx, cy, txt, Style(fg=Color256(245), italic=true))
end

function load_diff!(viewer::DiffViewer, text::String)
    viewer.state.files = parse_diff(text)
    viewer.state.current_file_idx = isempty(viewer.state.files) ? 0 : 1
    viewer.state.scroll_offset = 0
    viewer.state.selected_line = 1
end

function move_cursor!(state::DiffViewState, delta::Int)
    total = count_lines(state)
    state.selected_line = clamp(state.selected_line + delta, 1, max(1, total))
end

function toggle_view_mode!(state::DiffViewState)
    state.view_mode = state.view_mode == MODE_SPLIT ? MODE_UNIFIED : MODE_SPLIT
end

function toggle_word_wrap!(state::DiffViewState)
    state.word_wrap = !state.word_wrap
end

function next_file!(state::DiffViewState)
    isempty(state.files) && return
    state.current_file_idx = min(state.current_file_idx + 1, length(state.files))
    state.scroll_offset = 0
end

function prev_file!(state::DiffViewState)
    isempty(state.files) && return
    state.current_file_idx = max(state.current_file_idx - 1, 1)
    state.scroll_offset = 0
end

function count_lines(state::DiffViewState)::Int
    isempty(state.files) && return 0
    file = state.files[state.current_file_idx]
    total = 0
    for hunk in file.hunks
        total += 1  # hunk header
        total += count(l -> l.line_type != LINE_HUNK_HEADER, hunk.lines)
    end
    total
end

function render_diff_view(buf::Buffer, state::DiffViewState, x::Int, y::Int)
    isempty(state.files) && return render_empty_diff(buf, state, x, y)
    
    file = state.files[state.current_file_idx]
    render_file_header(buf, file, state, x, y)
    
    if state.view_mode == MODE_SPLIT
        render_split_view(buf, file, state, x, y + 2, state.height - 2)
    else
        render_unified_view(buf, file, state, x, y + 2, state.height - 2)
    end
end

function render_widget(buf::Buffer, viewer::DiffViewer, x::Int, y::Int, max_y::Int)
    viewer.state.height = max_y - y
    render_diff_view(buf, viewer.state, x, y)
end

# Export public API
export DiffViewer, DiffViewState, load_diff!, move_cursor!, toggle_view_mode!, toggle_word_wrap!
export next_file!, prev_file!, count_lines, render_widget, render_diff_view
export MODE_UNIFIED, MODE_SPLIT

end # module
