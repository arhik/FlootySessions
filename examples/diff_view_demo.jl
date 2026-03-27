# ═══════════════════════════════════════════════════════════════════════
# GitHub-Style Diff View Demo for FlootySessions
#
# This demonstrates the DiffViewer widget for displaying git diffs
# in a TUI interface similar to GitHub's diff view.
#
# Keys:
#   j / ↓           Move down one line
#   k / ↑           Move up one line
#   PageDown        Scroll down one page
#   PageUp          Scroll up one page
#   Tab             Toggle between split/unified view
#   f               Next file (if multiple files in diff)
#   F               Previous file
#   /               Search in diff
#   n               Next search result
#   N               Previous search result
#   c               Collapse/expand current hunk
#   C               Collapse/expand all hunks
#   l               Toggle line numbers
#   q / Ctrl+C      Quit
# ═══════════════════════════════════════════════════════════════════════

using Tachikoma
using FlootySessions

# Include the diff view component directly
include(joinpath(@__DIR__, "..", "src", "diff_view.jl"))
using .DiffView

@tachikoma_app

# ═══════════════════════════════════════════════════════════════════════
# Model
# ═══════════════════════════════════════════════════════════════════════

mutable struct DiffDemoModel
    viewer::DiffViewer
    status::String
    search_input::String
    search_mode::Bool
    
    function DiffDemoModel()
        # Create a viewer with initial dimensions
        viewer = DiffViewer(100, 30; view_mode=MODE_SPLIT)
        
        # Load sample diff data
        sample_diff = generate_sample_diff()
        load_diff!(viewer, sample_diff)
        
        new(viewer, "Tab: toggle view | j/k: scroll | /: search | q: quit", "", false)
    end
end


# ═══════════════════════════════════════════════════════════════════════
# Generate Sample Diff
# ═══════════════════════════════════════════════════════════════════════

function generate_sample_diff()::String
    """
--- a/src/config.jl
+++ b/src/config.jl
@@ -1,8 +1,9 @@
 module Config
 
-const DEFAULT_TIMEOUT = 30
+const DEFAULT_TIMEOUT = 60
 const MAX_RETRIES = 3
 const API_VERSION = "v2"
+const CACHE_ENABLED = true
 
 function get_timeout()
-    return DEFAULT_TIMEOUT
+    return DEFAULT_TIMEOUT + 5
 end
 
--- a/src/utils.jl
+++ b/src/utils.jl
@@ -10,25 +10,30 @@ module Utils
 using Dates
 
 struct Logger
     level::Int
     output::IOStream
+    timestamps::Bool
 end
 
-function Logger(level::Int=1)
-    Logger(level, stdout)
+function Logger(level::Int=1; timestamps=true)
+    Logger(level, stdout, timestamps)
 end
 
 function log_info(logger::Logger, msg::String)
+    if logger.timestamps
+        timestamp = Dates.now()
+        println(logger.output, "[\$timestamp] INFO: \$msg")
+    else
     println(logger.output, "INFO: \$msg")
+    end
 end
 
 function log_error(logger::Logger, msg::String)
-    println(logger.output, "ERROR: \$msg")
+    println(logger.output, "[\$(Dates.now())] ERROR: \$msg")
 end
 
 function format_duration(seconds::Int)::String
-    if seconds < 60
-        return "\$(seconds)s"
+    if seconds < 120
+        return "\$(div(seconds, 60))m \$(seconds % 60)s"
     else
         mins = div(seconds, 60)
         return "\$(mins)m"
@@ -36,7 +41,8 @@ function format_duration(seconds::Int)::String
 end
 
-export Logger, log_info, log_error
+# New exports
+export Logger, log_info, log_error, log_warn, format_duration
 
 end # module Utils
--- a/src/main.jl
+++ b/src/main.jl
@@ -1,5 +1,3 @@
-# Old deprecated import
-using LegacyCompat
-# Using legacy compatibility layer
+# Modern imports
 using JSON3
 using HTTP
@@ -8,7 +6,8 @@ using .Config
 using .Utils
 
 function main()
-    println("Starting application...")
+    logger = Utils.Logger(1; timestamps=true)
+    Utils.log_info(logger, "Starting application...")
     config = load_config()
     run_server(config)
 end
--- /dev/null
+++ b/src/new_feature.jl
@@ -0,0 +1,20 @@
+module NewFeature
+
+export compute_metrics, validate_input
+
+const METRIC_THRESHOLD = 0.95
+
+struct MetricResult
+    value::Float64
+    valid::Bool
+end
+
+function compute_metrics(data::Vector{Float64})::MetricResult
+    mean_val = sum(data) / length(data)
+    valid = mean_val > METRIC_THRESHOLD
+    return MetricResult(mean_val, valid)
+end
+
+function validate_input(data::Vector{Float64})::Bool
+    return !isempty(data) && all(isfinite, data)
+end
+
+end
"""
end


# ═══════════════════════════════════════════════════════════════════════
# Update Handler
# ═══════════════════════════════════════════════════════════════════════

function update!(m::DiffDemoModel)
    # Get terminal size for viewer
    w, h = Tachikoma.terminal_size()
    m.viewer.state.width = w - 2  # Leave margin
    m.viewer.state.height = h - 3  # Leave room for header/footer
end


# ═══════════════════════════════════════════════════════════════════════
# Input Handler
# ═══════════════════════════════════════════════════════════════════════

@input function handle_input(t::Tachikoma.Term, m::DiffDemoModel, ev::Tachikoma.Event)
    if m.search_mode
        handle_search_input!(t, m, ev)
        return
    end
    
    if ev isa Tachikoma.KeyEvent
        key = ev.key
        
        if key == :char && ev.ch == 'q'
            Tachikoma.quit!(t)
            
        elseif key == :char && ev.ch == 'j' || key == :down
            move_cursor!(m.viewer.state, 1)
            m.status = "Line $(m.viewer.state.selected_line)"
            
        elseif key == :char && ev.ch == 'k' || key == :up
            move_cursor!(m.viewer.state, -1)
            m.status = "Line $(m.viewer.state.selected_line)"
            
        elseif key == :page_down
            move_cursor!(m.viewer.state, m.viewer.state.height)
            m.status = "Page down"
            
        elseif key == :page_up
            move_cursor!(m.viewer.state, -m.viewer.state.height)
            m.status = "Page up"
            
        elseif key == :char && ev.ch == '\t'
            toggle_view_mode!(m.viewer.state)
            mode_str = m.viewer.state.view_mode == MODE_SPLIT ? "SPLIT" : "UNIFIED"
            m.status = "View mode: $mode_str"
            
        elseif key == :char && ev.ch == 'f'
            next_file!(m.viewer.state)
            file = m.viewer.state.files[m.viewer.state.current_file_idx]
            m.status = "File: $(file.new_path)"
            
        elseif key == :char && ev.ch == 'F'
            prev_file!(m.viewer.state)
            file = m.viewer.state.files[m.viewer.state.current_file_idx]
            m.status = "File: $(file.new_path)"
            
        elseif key == :char && ev.ch == '/'
            m.search_mode = true
            m.search_input = ""
            m.status = "Search: "
            
        elseif key == :char && ev.ch == 'l'
            m.viewer.state.show_line_numbers = !m.viewer.state.show_line_numbers
            m.status = m.viewer.state.show_line_numbers ? "Line numbers: ON" : "Line numbers: OFF"
            
        elseif key == :char && ev.ch == 'c'
            # Toggle current hunk (simplified - would need hunk detection)
            m.status = "Hunk toggled"
            
        elseif key == :char && ev.ch == 'C'
            m.viewer.state.expand_all = !m.viewer.state.expand_all
            m.status = m.viewer.state.expand_all ? "All hunks expanded" : "Hunks collapsible"
            
        elseif key == :char && ev.ch == 'n'
            next_search_result!(m.viewer.state)
            m.status = "Next result"
            
        elseif key == :char && ev.ch == 'N'
            prev_search_result!(m.viewer.state)
            m.status = "Previous result"
            
        elseif key == :ctrl_c || key == :esc
            Tachikoma.quit!(t)
        end
    end
end

function handle_search_input!(t::Tachikoma.Term, m::DiffDemoModel, ev::Tachikoma.Event)
    if ev isa Tachikoma.KeyEvent
        key = ev.key
        
        if key == :enter
            search!(m.viewer.state, m.search_input)
            m.status = "Searched for: $(m.search_input) ($(length(m.viewer.state.search_results)) results)"
            m.search_mode = false
            m.search_input = ""
            
        elseif key == :esc
            m.search_mode = false
            m.search_input = ""
            m.status = "Search cancelled"
            
        elseif key == :backspace
            if !isempty(m.search_input)
                m.search_input = m.search_input[1:end-1]
                m.status = "Search: $m.search_input"
            end
            
        elseif key == :char
            m.search_input *= ev.ch
            m.status = "Search: $m.search_input"
        end
    end
end


# ═══════════════════════════════════════════════════════════════════════
# Render UI
# ═══════════════════════════════════════════════════════════════════════

@render function render_diff_demo(m::DiffDemoModel)
    w, h = Tachikoma.terminal_size()
    
    buf = Tachikoma.Buffer(w, h)
    
    # Header
    header_style = Style(bg=ColorRGB(40, 40, 60), fg=ColorRGB(200, 200, 255), bold=true)
    header_text = rpad("  GitHub-Style Diff Viewer | $(m.viewer.state.current_file_idx)/$(length(m.viewer.state.files)) files", w)
    set(buf, 0, 0, Cell(header_text, header_style))
    
    # Separator
    sep_style = Style(fg=Color256(239))
    set(buf, 0, 1, Cell("─" ^ w, sep_style))
    
    # Diff view
    if m.search_mode
        # Show search input
        search_style = Style(bg=ColorRGB(60, 60, 60), fg=ColorRGB(255, 255, 255))
        search_text = rpad(" Search: $(m.search_input)_ ", w)
        set(buf, 0, h - 2, Cell(search_text, search_style))
    else
        # Render diff viewer
        m.viewer.state.height = h - 4  # Account for header, separator, and status
        render_widget(buf, m.viewer, 0, 2, h - 2)
    end
    
    # Status bar
    status_style = Style(bg=ColorRGB(60, 60, 60), fg=ColorRGB(200, 200, 200))
    status_text = rpad(" $(m.status)", w)
    set(buf, 0, h - 1, Cell(status_text, status_style))
    
    buf
end


# ═══════════════════════════════════════════════════════════════════════
# Main Entry
# ═══════════════════════════════════════════════════════════════════════

# Instructions printed before TUI starts
println("GitHub-Style Diff Viewer Demo")
println("=============================")
println()
println("Controls:")
println("  j/↓, k/↑       Move down/up")
println("  PageDown/Up    Scroll by page")
println("  Tab            Toggle split/unified view")
println("  f/F            Next/previous file")
println("  /              Search in diff")
println("  n/N            Next/previous search result")
println("  l              Toggle line numbers")
println("  c/C            Toggle hunk/all hunks")
println("  q/Ctrl+C       Quit")
println()
println("Loading sample diff...")
sleep(1)

# Start the app
start(DiffDemoModel(), rate=60.0)