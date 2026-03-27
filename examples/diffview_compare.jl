# ═══════════════════════════════════════════════════════════════════════
# Code Diff Viewer - Standalone Tachikoma Application
# ═══════════════════════════════════════════════════════════════════════

using Dates
using IOCapture

try
    using Tachikoma
catch
    using Pkg
    Pkg.add(url="https://github.com/badlogic/Tachikoma.jl")
    using Tachikoma
end

include(joinpath(@__DIR__, "..", "src", "diff_view.jl"))
using .DiffView

@tachikoma_app

mutable struct CompareModel <: Tachikoma.Model
    viewer::DiffView.DiffViewer
    file1::String
    file2::String
    status::String
    should_exit::Bool
    
    function CompareModel(f1::String, f2::String)
        v = DiffView.DiffViewer(100, 30; view_mode=DiffView.MODE_SPLIT)
        local msg
        
        try
            if isempty(f1) && isempty(f2)
                # Use sample diff
                diff_text = sample_diff()
                load_diff!(v, diff_text)
                f1, f2 = "sample", "modified"
                msg = "Tab:toggle j/k:scroll l:line# w:wrap y:approve n:deny"
            else
                # Try system diff first, then fallback
                diff_text = generate_diff(f1, f2)
                load_diff!(v, diff_text)
                msg = "Tab:toggle j/k:scroll l:line# w:wrap y:approve n:deny"
            end
        catch e
            # Show error in diff view
            diff_text = """--- a/error
+++ b/error
@@ -1,1 +1,1 @@
-$(sprint(showerror, e))
+Error: $(sprint(showerror, e))
"""
            load_diff!(v, diff_text)
            msg = "Error: $(sprint(showerror, e))"
        end
        new(v, f1, f2, msg, false)
    end
end

function Tachikoma.view(m::CompareModel, frame::Tachikoma.Frame)
    buf = frame.buffer
    w, h = frame.area.width, frame.area.height
    
    # Header
    header = " $(m.file1) → $(m.file2) "
    Tachikoma.set_string!(buf, 0, 0, rpad(header, w), Tachikoma.Style(fg=Tachikoma.ColorRGB(100, 255, 100), bold=true))
    Tachikoma.set_string!(buf, 0, 1, "─" ^ w, Tachikoma.Style(fg=Tachikoma.Color256(239)))
    
    # Diff view
    m.viewer.state.width = w
    m.viewer.state.height = h - 4
    DiffView.render_widget(buf, m.viewer, 0, 2, h - 2)
    
    # Status
    Tachikoma.set_string!(buf, 0, h - 1, rpad(" $(m.status)", w), Tachikoma.Style(fg=Tachikoma.ColorRGB(200, 200, 200)))
end

function Tachikoma.update!(m::CompareModel, ev::Tachikoma.Event)
    ev isa Tachikoma.KeyEvent || return
    k = ev.key
    
    if k == :char && ev.char == 'q'
        m.should_exit = true
    elseif k == :escape
        m.should_exit = true
    elseif k == :char && ev.char == 'j' || k == :down
        DiffView.move_cursor!(m.viewer.state, 1)
        m.status = "Line $(m.viewer.state.selected_line)"
    elseif k == :char && ev.char == 'k' || k == :up
        DiffView.move_cursor!(m.viewer.state, -1)
        m.status = "Line $(m.viewer.state.selected_line)"
    elseif k == :page_down
        DiffView.move_cursor!(m.viewer.state, m.viewer.state.height)
        m.status = "Page down"
    elseif k == :page_up
        DiffView.move_cursor!(m.viewer.state, -m.viewer.state.height)
        m.status = "Page up"
    elseif k == :char && ev.char == '\t'
        DiffView.toggle_view_mode!(m.viewer.state)
        m.status = "View mode: $(m.viewer.state.view_mode == DiffView.MODE_SPLIT ? "SPLIT" : "UNIFIED")"
    elseif k == :char && ev.char == 'l'
        m.viewer.state.show_line_numbers = !m.viewer.state.show_line_numbers
        m.status = m.viewer.state.show_line_numbers ? "Line numbers: ON" : "Line numbers: OFF"
    elseif k == :char && ev.char == 'w'
        DiffView.toggle_word_wrap!(m.viewer.state)
        m.status = m.viewer.state.word_wrap ? "Word wrap: ON" : "Word wrap: OFF"
    elseif k == :char && ev.char == 'f'
        DiffView.next_file!(m.viewer.state)
        m.status = "File $(m.viewer.state.current_file_idx)/$(length(m.viewer.state.files))"
    elseif k == :char && ev.char == 'F'
        DiffView.prev_file!(m.viewer.state)
        m.status = "File $(m.viewer.state.current_file_idx)/$(length(m.viewer.state.files))"
    end
end

Tachikoma.should_quit(m::CompareModel) = m.should_exit

function sample_diff()::String
    """
--- a/utils.jl
+++ b/utils.jl
@@ -1,5 +1,6 @@
 module Utils
 
+using Dates
 struct Logger
     level::Int
 end
--- a/main.jl
+++ b/main.jl
@@ -1,3 +1,2 @@
-using LegacyCompat
 function main()
     println("Hello")
 end
@@ -1,0 +1,8 @@
+module New
+
+export hello
+
+function hello()
+    println("Hello")
+end
+
+end
"""
end

# Generate unified diff from two files using system diff if available
function generate_diff(f1::String, f2::String)::String
    !isfile(f1) && error("File not found: $f1")
    !isfile(f2) && error("File not found: $f2")
    
    # Try system diff first using IOCapture (diff returns exit code 1 when files differ)
    result = IOCapture.capture(rethrow=Union{}) do
        run(`diff -u "$f1" "$f2"`)
    end
    
    # IOCapture captures stdout even on non-zero exit
    if length(result.output) > 0
        return result.output
    end
    
    # Fallback to simple diff
    return simple_diff(f1, f2)
end

# Simple line-by-line diff generator
function simple_diff(f1::String, f2::String)::String
    old = readlines(f1)
    new = readlines(f2)
    
    io = IOBuffer()
    println(io, "--- a/", basename(f1))
    println(io, "+++ b/", basename(f2))
    println(io, "@@ -1,$(length(old)) +1,$(length(new)) @@")
    
    max_lines = max(length(old), length(new))
    for i in 1:max_lines
        o = i <= length(old) ? old[i] : nothing
        n = i <= length(new) ? new[i] : nothing
        
        if o !== nothing && n !== nothing && o == n
            println(io, " ", o)
        elseif o !== nothing
            println(io, "-", o)
        end
        
        if n !== nothing && (o === nothing || o != n)
            println(io, "+", n)
        end
    end
    
    String(take!(io))
end

function main()
    f1, f2 = "", ""
    
    if length(ARGS) >= 2
        f1, f2 = ARGS[1], ARGS[2]
    elseif length(ARGS) == 1 && (ARGS[1] == "-h" || ARGS[1] == "--help")
        println("Usage: julia diffview_compare.jl [file1] [file2]")
        println()
        println("Compare two files with GitHub-style diff view.")
        println()
        println("Keys:")
        println("  Tab          Toggle split/unified view")
        println("  j, ↓         Move cursor down")
        println("  k, ↑         Move cursor up")
        println("  l            Toggle line numbers")
        println("  f            Next file")
        println("  F            Previous file")
        println("  q, Esc       Quit")
        return
    else
        println("Running with sample data...")
        println("Pass two files to compare them.")
    end
    
    Tachikoma.app(CompareModel(f1, f2), fps=60)
end

# Only run main() when executed directly (not when included)
if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
