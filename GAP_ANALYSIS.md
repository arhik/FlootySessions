# FlootyTUI vs tui.jl Gap Analysis Document

## Executive Summary

This document provides a comprehensive comparison between FlootyTUI (client-server architecture) and FlootySessions/examples/tui.jl (standalone). It identifies functional gaps, bugs, and architectural differences.

**Status**: 🔴 Multiple critical bugs and missing features identified

---

## 1. Critical Bugs 🐛

### Bug 1: Undefined Variable `key` in UI.jl
**File**: `FlootyTUI/src/ui/UI.jl` (Lines 319-338)
**Severity**: 🔴 Critical - Code will crash at runtime

```julia
# CURRENT (BROKEN):
if m.message_select_mode && m.selected_message_idx !== nothing
    _handle_message_select_key(m, key)  # ← 'key' is undefined!
    return
end

# SHOULD BE:
if m.message_select_mode && m.selected_message_idx !== nothing
    _handle_message_select_key(m, evt)
    return
end
```

**Impact**: Event handling for message selection, attachment, sidebar, and chat input will fail.

**Fix Required**: Replace all 4 occurrences of `key` with `evt` on lines 321, 327, 333, 338.

---

### Bug 2: NameGeneratedResponse Field Mismatch
**File**: `FlootyTUI/src/protocol/Protocol.jl` (Line 195)
**Severity**: 🔴 High - Will cause runtime error

```julia
# CURRENT (WRONG):
function _handle_dispatch(m::TuiModel, msg::NameGeneratedResponse)
    _debug_log("NameGeneratedResponse: $(msg.name)")  # ← field is 'generated_name'
    ...
    m.sessions[i] = SessionInfo(s.id, msg.name, ...)  # ← wrong field name

# SHOULD BE:
function _handle_dispatch(m::TuiModel, msg::NameGeneratedResponse)
    _debug_log("NameGeneratedResponse: $(msg.generated_name)")
    ...
    m.sessions[i] = SessionInfo(s.id, msg.generated_name, ...)
```

---

### Bug 3: ExecuteToolRequest Missing Arguments
**File**: `FlootyTUI/src/actions/Actions.jl` (Line 170)
**Severity**: 🔴 High - Protocol mismatch

```julia
# CURRENT (WRONG):
send_request(m.client, ExecuteToolRequest(
    "execute_tool", m.current_session_id, tool_call_id, execute, now()
))

# SHOULD BE:
send_request(m.client, ExecuteToolRequest(
    "execute_tool", m.current_session_id, tool_call_id,
    tool_name, arguments, execute, now()
))
```

---

### Bug 4: SaveSessionsResponse Missing Argument
**File**: `FlootyCore/src/FlootyCore.jl` (Line 342)
**Severity**: 🟡 Medium

```julia
# CURRENT:
return SaveSessionsResponse("sessions_saved", now())

# SHOULD BE:
count = length(list_sessions(model.manager))
return SaveSessionsResponse("sessions_saved", count, now())
```

---

## 2. Text Input Handling 📄

### Issue 1: Manual Rendering Bypasses TextInput Widget
**File**: `FlootyTUI/src/ui/UI.jl` (Lines 173-194)

| Aspect | tui.jl (Correct) | FlootyTUI (Incorrect) |
|--------|------------------|----------------------|
| Rendering | `render(m.input, inner_area, buf)` | Manual `set_string!` calls |
| Cursor | Widget handles internally | Manual positioning with `█` |
| Text wrapping | Widget handles | Manual truncation with `...` |
| Multi-line | Yes (3 lines) | No (1 line only) |

**Impact**:
- No multi-line input support
- UTF-8 characters may cause cursor misalignment
- Manual truncation loses content
- No horizontal scrolling

**Recommended Fix**:
```julia
# Replace lines 173-194 with:
input_area = Rect(chat_x, input_y, chat_width, 3)
m.input.style = input_style
m.input.focused = !m.sidebar_focused && m.modal == MODAL_NONE
m.input.tick = m.tick
render(m.input, input_area, buf)
```

---

### Issue 2: TextInput Construction Inconsistency
**File**: `FlootyTUI/src/types/Types.jl` (Line 49)

```julia
# CURRENT:
input::TextInput = TextInput(; text="", focused=true, tick=0)

# tui.jl uses:
input::TextInput = TextInput(text="", focused=true, tick=0)
```

Note: Semicolon vs comma - both work but should be consistent.

---

## 3. Layout & Rendering 📐

### Layout Comparison

| Feature | tui.jl | FlootyTUI | Status |
|---------|--------|-----------|--------|
| Sidebar width | Fixed 35 chars | `min(35, div(term_w, 4))` | ⚠️ Different |
| Separator char | `┃` (heavy vertical) | `│` (light vertical) | ⚠️ Different |
| Activity panel | Yes (1 line) | No | ❌ Missing |
| Queue panel | Yes (dynamic, max 5 lines) | No | ❌ Missing |
| Input height | 3 lines | 1 line | ❌ Different |
| Status bar | Dedicated area | Bottom line | ⚠️ Different |
| Modal rendering | Full implementation | Partial | ⚠️ Incomplete |

---

### Missing Panel: Activity
**tui.jl has** (`_render_activity_panel!`):
- Shows streaming status
- Background task indicators
- Spinner animations

**FlootyTUI**: Not implemented

---

### Missing Panel: Queue
**tui.jl has** (`_render_queue_panel!`):
- Shows queued messages when LLM is busy
- Select/Copy/Delete queued items
- Dynamic height (max 5 lines)

**FlootyTUI**: Has data structure but no rendering

---

## 4. Key Event Handling ⌨️

### Key Binding Differences

| Key | tui.jl | FlootyTUI | Issue |
|-----|--------|-----------|-------|
| **Ctrl+C** | Quit + auto-save | Quit + disconnect | ⚠️ No auto-save |
| **F2** | Toggle sidebar | Toggle sidebar | ✅ Match |
| **F3** | New session | New session | ✅ Match |
| **F4** | Delete session **modal** | Delete session (no modal) | ⚠️ No confirmation |
| **F5** | Force save | Save sessions | ✅ Match |
| **F6** | Model select | Model select | ✅ Match |
| **F7** | Message select | Message select | ✅ Match |
| **F8** | System prompt modal | No-op (comment) | ❌ Not implemented |
| **F9** | Save edit (in edit mode) | N/A | ❌ Missing |
| **F12** | Toggle sidebar | N/A | ❌ Missing |
| **Tab** | Switch focus | Switch focus | ✅ Match |
| **Esc** | Interrupt/cancel | Interrupt/cancel | ✅ Match |
| **@** | Attachment mode | Attachment mode | ✅ Match |
| **q** | Queue select mode | N/A | ❌ Missing |
| **End** | Scroll to bottom | N/A | ❌ Missing |

---

### Key Handler Bug
**File**: `FlootyTUI/src/ui/UI.jl` (Lines 319-338)

All handler calls use undefined variable `key` instead of `evt`:
- Line 321: `_handle_message_select_key(m, key)`
- Line 327: `_handle_attachment_key(m, key)`
- Line 333: `_handle_sidebar_key(m, key)`
- Line 338: `_handle_chat_input_key(m, key)`

---

## 5. Modal System 🗔️

### Modal Types Comparison

| Modal | tui.jl | FlootyTUI | Status |
|-------|--------|-----------|--------|
| MODAL_NONE | ✅ | ✅ | Match |
| MODAL_DELETE_CONFIRM | Full impl | Enum only | ❌ Missing |
| MODAL_MODEL_SELECT | Full impl | Partial | ⚠️ Incomplete |
| MODAL_DIFF_VIEW | Full impl | Enum only | ❌ Missing |
| MODAL_SYSTEM_PROMPT | Full impl | Enum only | ❌ Missing |
| Edit mode | TextArea-based | Not implemented | ❌ Missing |

---

### Missing Modal: Delete Confirmation
**tui.jl**: Shows confirmation dialog with Cancel/Confirm buttons
**FlootyTUI**: Directly calls `close_session!()` without confirmation

---

### Missing Modal: System Prompt
**tui.jl**: Shows F8 system prompt with scrolling text
**FlootyTUI**: Commented as "Show help/system prompt" but not implemented

---

### Missing Modal: Diff View
**tui.jl**: Shows diff between edited messages
**FlootyTUI**: Enum exists but no implementation

---

## 6. Data Model Differences 📊

### TuiModel Field Comparison

| Field | tui.jl | FlootyTUI | Issue |
|-------|--------|-----------|-------|
| `manager` | `SessionManager` | N/A (uses `client`) | ⚠️ Architectural diff |
| `current_session` | `Session` object | `current_session_id::String` | ⚠️ By-reference vs By-id |
| `session_list` | `SelectableList` | N/A | ❌ Missing |
| `edit_mode` | `Bool` | N/A | ❌ Missing |
| `edit_attachments` | `Vector{Attachment}` | N/A | ❌ Missing |
| `modal_input` | `TextInput` | N/A | ❌ Missing |
| `message_queue` | `Vector{String}` | Exists but unused | ⚠️ Partial |
| `last_save` | `DateTime` | N/A | ❌ Missing |
| `streaming_session_id` | `Union{UUID,Nothing}` | `Union{String,Nothing}` | ⚠️ Type diff |

---

## 7. Protocol/Communication 🔌

### Protocol Message Coverage

| Feature | tui.jl | FlootyTUI | Status |
|---------|--------|-----------|--------|
| Session create | Direct | Via WebSocket | ✅ Covered |
| Session switch | Direct | Via WebSocket | ✅ Covered |
| Message send | Direct | Via WebSocket | ✅ Covered |
| Streaming | Direct | Via WebSocket events | ✅ Covered |
| Tool calls | Direct execution | Client confirmation | ⚠️ Different |
| Auto-save | Local | Server-side | ⚠️ Different |

---

### Tool Call Flow Difference

**tui.jl (Direct)**:
1. LLM returns tool call
2. Tool executes immediately
3. Result added to context

**FlootyTUI (Client Confirmation)**:
1. LLM returns tool call
2. Server sends `ToolCallEvent`
3. Client shows confirmation prompt
4. Client sends `ExecuteToolRequest`
5. Server executes or cancels

This is an intentional architectural difference for client control.

---

## 8. Feature Inventory ✅/❌

### Implemented in Both
- ✅ Basic chat interface
- ✅ Session management
- ✅ Message display with styling
- ✅ Sidebar with session list
- ✅ Keyboard navigation (F2-F7)
- ✅ Message selection mode (F7)
- ✅ Attachment support (@ key)
- ✅ Markdown rendering for assistant messages
- ✅ Streaming response display
- ✅ Tool call display

### Missing in FlootyTUI
- ❌ Delete confirmation modal (F4 is immediate)
- ❌ System prompt display (F8)
- ❌ Edit mode for messages (F9 to save)
- ❌ Queue panel (q key)
- ❌ Activity panel
- ❌ Multi-line text input
- ❌ Horizontal scroll in input
- ❌ Diff view modal
- ❌ Modal input widget
- ❌ Auto-save indicator
- ❌ Session persistence status (saved/unsaved)
- ❌ Last save time tracking
- ❌ Agent count in status bar

### Different Behavior
- ⚠️ Tool execution requires confirmation in FlootyTUI
- ⚠️ F4 delete is immediate vs modal confirmation
- ⚠️ Streaming interruption handling
- ⚠️ Message sending while streaming (queue vs immediate)

---

## 9. Styling/Themes 🎨

### Style Constants Comparison

| Constant | tui.jl | FlootyTUI | Status |
|----------|--------|-----------|--------|
| `GREY_TEXT` | `Color256(245)` | `Color256(245)` | ✅ |
| `GREY_DIM` | `Color256(239)` | `Color256(239)` | ✅ |
| `GREY_BG` | `ColorRGB(40,40,40)` | `ColorRGB(40,40,40)` | ✅ |
| `USER_BG` | `ColorRGB(60,60,60)` | `ColorRGB(60,60,60)` | ✅ |
| `ASSISTANT_BG` | `ColorRGB(40,40,60)` | `ColorRGB(40,40,60)` | ✅ |
| `TOOL_BG` | `ColorRGB(40,80,40)` | `ColorRGB(40,80,40)` | ✅ |
| `SYSTEM_BG` | `ColorRGB(80,60,40)` | `ColorRGB(80,60,40)` | ✅ |
| `SEPARATOR` | `Color256(239)` | `Color256(239)` | ✅ |
| `HIGHLIGHT` | `ColorRGB(100,255,100)` | `ColorRGB(100,255,100)` | ✅ |
| `ACTIVE_SESSION` | `ColorRGB(255,255,100)` | `ColorRGB(255,255,100)` | ✅ |
| `INACTIVE_SESSION` | `Color256(245)` | `Color256(245)` | ✅ |
| `SAVED_STATUS` | `ColorRGB(100,255,100)` | N/A | ❌ Missing |
| `UNSAVED_STATUS` | `ColorRGB(255,100,100)` | N/A | ❌ Missing |

**Styles**: 92% match (11/13 constants)

---

## 10. Code Quality Metrics 📈

### File Organization

| Aspect | tui.jl | FlootyTUI |
|--------|--------|-----------|
| Lines of code | ~2700 | ~1500 |
| Files | 1 | 7 (modularized) |
| Modules | 1 | 6 submodules |
| Functions | ~50 | ~40 |

### Complexity Comparison

| Metric | tui.jl | FlootyTUI |
|--------|--------|-----------|
| View function | ~75 lines | ~165 lines |
| Key handler | ~285 lines | ~120 lines (split) |
| Input handling | Integrated | Manual rendering |

---

## 11. Prioritized Fix List 🔧

### P0 (Critical - Fix Immediately)
1. **Bug 1**: Undefined `key` variable in UI.jl (lines 321, 327, 333, 338)
2. **Bug 2**: `msg.name` should be `msg.generated_name` in Protocol.jl
3. **Bug 3**: `ExecuteToolRequest` missing arguments in Actions.jl

### P1 (High Priority)
4. **Text Input**: Replace manual rendering with `render(m.input, ...)`
5. **Add session_list**: `SelectableList` for sidebar navigation
6. **Add edit_mode**: Support in-place message editing

### P2 (Medium Priority)
7. **Add modals**: Delete confirmation, system prompt, diff view
8. **Add panels**: Activity, queue panels
9. **Add missing keys**: F9 (save edit), F12 (toggle sidebar), End (scroll bottom)
10. **Add status indicators**: Saved/unsaved, agent count

### P3 (Low Priority)
11. **Change separator**: `│` → `┃`
12. **Add last_save tracking**: For auto-save indicators
13. **Unify input construction**: Remove semicolon in TextInput

---

## 12. Testing Recommendations 🧪

### Critical Paths to Test
1. Message selection mode (F7) - blocked by Bug 1
2. Attachment mode (@) - blocked by Bug 1
3. Sidebar navigation - blocked by Bug 1
4. Chat input - blocked by Bug 1
5. Tool call confirmation - blocked by Bug 3
6. Session name generation - blocked by Bug 2

### Regression Tests
1. Basic chat send/receive
2. Session create/switch/close
3. Streaming display
4. Markdown rendering
5. Key bindings F2-F8

---

## Appendix A: Line References

### Critical Bugs
| Bug | File | Lines |
|-----|------|-------|
| Undefined `key` | `FlootyTUI/src/ui/UI.jl` | 321, 327, 333, 338 |
| `msg.name` | `FlootyTUI/src/protocol/Protocol.jl` | 195, 199 |
| `ExecuteToolRequest` | `FlootyTUI/src/actions/Actions.jl` | 170 |
| `SaveSessionsResponse` | `FlootyCore/src/FlootyCore.jl` | 342 |

### Text Input Issues
| Issue | File | Lines |
|-------|------|-------|
| Manual rendering | `FlootyTUI/src/ui/UI.jl` | 173-194 |
| Single line | `FlootyTUI/src/ui/UI.jl` | 174 |
| Cursor position | `FlootyTUI/src/ui/UI.jl` | 191-193 |

---

**Document Version**: 1.0
**Last Updated**: 2025-01-09
**Author**: Claude Code
