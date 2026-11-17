# inkpane-mcp

**Eyes for AI coding agents on macOS.** `inkpane-mcp` is a local [Model Context Protocol](https://modelcontextprotocol.io) server that lets Claude Code, Codex and other MCP clients take screenshots of your screen, a window or a region, read on-screen text with Apple's on-device OCR, and list the windows that are open.

- 100% local: ScreenCaptureKit for capture, Vision for OCR. Nothing leaves your Mac.
- Images come back as MCP image content (PNG), downscaled by default to save tokens. The full-resolution file is saved to disk and its path is included in the result.
- OCR returns text plus per-line bounding boxes in screen coordinates, so an agent can say *where* something is.
- `get_ui_tree` returns a window's Accessibility tree (roles, labels, identifiers, state, frames), and `diff_screenshots` shows what changed between two screenshots, or between one and the screen now.
- Two ready-made prompts, `report_ui_bug` and `explain_error_on_screen`, chain the tools for common jobs.
- Speaks MCP over stdio, or over Streamable HTTP on 127.0.0.1 with a bearer token (`--http`).
- With the Inkpane menu bar app running, agents can also **point and ask**: draw boxes, arrows, text, highlights and spotlights on your screen (`annotate_screen`), and ask you to circle something and get back its region, a screenshot and its text (`wait_for_user_annotation`), record the screen to an MP4 with those marks in the video (`record_action`), and capture a whole scrolling page as one long image (`capture_scrolling`). Without the app, every other tool works on its own.
- With the app running, **screen reads go through it**: you're asked once before a new agent can look, password managers and chat apps are left out, personal data can be blacked out, and an "agent is viewing" indicator shows while it looks. See [With or without the Inkpane app](#with-or-without-the-inkpane-app).
- Ships as a Swift package with a reusable library, `InkpaneKit`, and the `inkpane-mcp` executable.

Requires macOS 14 or later.

## Build

```bash
git clone <this repo>
cd inkpane-mcp
swift build -c release
```

The binary is at `.build/release/inkpane-mcp`. Copy it somewhere stable if you like (for example `~/.local/bin/inkpane-mcp`); MCP clients need an absolute path.

```bash
.build/release/inkpane-mcp --version
.build/release/inkpane-mcp --check   # Screen Recording status (and for which app), and whether the Inkpane app is reachable
```

Run the tests with `swift test`. They don't need any permission and never talk to a running Inkpane app.

## Connect it to your agent

### Claude Code

```bash
claude mcp add inkpane -- /absolute/path/to/inkpane-mcp
```

Add `--scope user` to make it available in every project. Then ask something like *"take a screenshot of the Simulator window and tell me why the button is misaligned"*.

### Codex CLI

```bash
codex mcp add inkpane -- /absolute/path/to/inkpane-mcp
```

Or add it to `~/.codex/config.toml` by hand:

```toml
[mcp_servers.inkpane]
command = "/absolute/path/to/inkpane-mcp"
args = []
# Optional: where captures are saved (default: $TMPDIR/inkpane-mcp)
# env = { INKPANE_MCP_OUTPUT_DIR = "/Users/me/Screenshots/agent" }
```

### Other clients (Claude Desktop, Cursor, VS Code, ...)

Any client that launches stdio MCP servers works. The usual JSON shape:

```json
{
  "mcpServers": {
    "inkpane": { "command": "/absolute/path/to/inkpane-mcp" }
  }
}
```

### Over HTTP (Streamable HTTP)

For clients that connect to a URL instead of starting a process, run the server yourself and keep it running:

```bash
/absolute/path/to/inkpane-mcp --http            # http://127.0.0.1:47823/mcp
/absolute/path/to/inkpane-mcp --http --port 9123 --require-app
```

The first start creates a random bearer token in `mcp-http.token` (mode `0600`) next to the Inkpane app's `agent.token` (see `INKPANE_APP_DIR`) and prints it once; later starts reuse it, and deleting the file makes a new one. Point the client at the URL with the token:

```json
{
  "mcpServers": {
    "inkpane": {
      "type": "http",
      "url": "http://127.0.0.1:47823/mcp",
      "headers": { "Authorization": "Bearer <contents of mcp-http.token>" }
    }
  }
}
```

```bash
claude mcp add --transport http inkpane http://127.0.0.1:47823/mcp --header "Authorization: Bearer $(cat ~/Library/Application\ Support/app.inkpane.Inkpane/mcp-http.token)"
```

The Inkpane app's Settings → Agents → Other Clients → **Copy HTTP Config** copies this JSON with the token filled in (and creates the token if needed).

Security:

- **Loopback only.** The listener binds to `127.0.0.1` and accepts only local connections; nothing on your network can reach it.
- **Bearer token on every request**, compared in constant time; without it the answer is `401`. Any local process that can read the token file (only your user) can use the server, just like `agent.token`.
- **DNS-rebinding protection.** The `Host` header must be `127.0.0.1:<port>`, `localhost:<port>` or `[::1]:<port>` (else `421`), and an `Origin` header, when present, must be a loopback origin (else `403`). No CORS headers are sent, so a web page can't make authenticated requests either.
- One request per connection, request bodies up to 8 MB with a `Content-Length` (no chunked uploads), at most 32 open sessions; sessions idle for 4 hours are closed (the client then starts a new one).

It serves the same tools, resources and prompts as stdio. Each MCP session (`Mcp-Session-Id`) has its own server; responses to `POST` are Server-Sent Event streams, `DELETE` ends a session, and `GET` answers `405` because the server never sends unsolicited messages. The transport and session handling are the Swift MCP SDK's `StatefulHTTPServerTransport` (0.12.1); the SDK has no HTTP listener, so `inkpane-mcp` adds a minimal HTTP/1.1 one on Network.framework (`Sources/InkpaneMCP/HTTP/`). With the Inkpane app running, the app sees one `inkpane-mcp` process for all HTTP sessions: an **Allow Once** answer covers every session until the server stops, and each session is shown with its own client name.

## Permissions

Capturing the screen needs macOS **Screen Recording** permission. macOS grants it to the *app that launched the server*, not to `inkpane-mcp` itself:

| You run the agent in | Grant Screen Recording to |
|---|---|
| Terminal, iTerm2, Ghostty, Warp, ... | that terminal app |
| VS Code / Cursor integrated terminal or extension | Visual Studio Code / Cursor |
| Claude Desktop, other GUI clients | that app |

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**.
2. Turn the app on (use **+** if it isn't listed).
3. **Quit and reopen that app.** macOS only applies the change after a restart.

If permission is missing, every capture tool returns an error naming the app it detected as the launcher (for example *"Enable "iTerm2" in System Settings → …"*), and the first failed call makes macOS show its permission prompt. `inkpane-mcp --check` prints the same diagnosis from your shell.

Notes:

- `list_windows` works without permission, but macOS hides other apps' window titles until it is granted.
- Since macOS 15, macOS periodically asks you to confirm apps that can record the screen. Confirm it for your terminal or client to keep captures working.
- OCR on an existing image file (`read_screen_ocr` with `image_path`) and `diff_screenshots` on two files need no permission.
- `get_ui_tree` needs **Accessibility** permission (System Settings → Privacy & Security → Accessibility) for the same launching app, or for the Inkpane app when it runs. The first call without it shows the system prompt and returns an error naming the app to enable. `inkpane-mcp --check` shows its status too.

## Tools

All coordinates are **global screen points**: the origin is the top-left corner of the main display, y grows downward, and displays to the left of or above the main display have negative coordinates. That's the space used by `list_windows` frames, region arguments and OCR `screen_box` values. On a Retina display, one point is two pixels.

Every capture tool takes `max_dimension`: the longest edge, in pixels, of the image returned to the client. The default is `1568`; `0` returns full resolution. The file saved to disk is always full resolution. The text result is a summary line plus JSON metadata:

```json
{
  "kind": "window",
  "path": "/var/folders/.../inkpane-mcp/capture-20261030-144434-656-window.png",
  "frame": { "x": -212, "y": -1410, "width": 2331, "height": 1329 },
  "scale": 1,
  "pixel_width": 2331, "pixel_height": 1329,
  "returned_width": 800, "returned_height": 456,
  "points_per_returned_pixel": 2.9138,
  "window": { "window_id": 492, "app_name": "...", "bundle_id": "...", "title": "...", "...": "..." }
}
```

To turn a pixel `(px, py)` in the returned image into screen points, compute `frame.x + px * points_per_returned_pixel` (and the same for y).

### `capture_screen`

Screenshot a whole display.

| Argument | Type | Default | |
|---|---|---|---|
| `display` | integer | `0` | Display index from `list_windows`; `0` is the main display. |
| `max_dimension` | integer | `1568` | |

### `capture_window`

Screenshot a single window, even if other windows partly cover it. Pass `window_id` **or** `app`.

| Argument | Type | |
|---|---|---|
| `window_id` | integer | From `list_windows`. |
| `app` | string | App name (`Safari`) or bundle id (`com.apple.Safari`). Captures the app's frontmost on-screen window. |
| `title` | string | With `app`: only windows whose title contains this text (case-insensitive). |
| `max_dimension` | integer | |

### `capture_region`

Screenshot a rectangle. A region that spans displays is clipped to the display it overlaps most, and the metadata includes a `note` when that happens.

| Argument | Type | |
|---|---|---|
| `x`, `y`, `width`, `height` | number (required) | Global screen points. |
| `max_dimension` | integer | |

### `read_screen_ocr`

Recognize text on-device with Apple Vision. Choose **one** target: `display`, `window_id`, `app` (+ `title`), a region (`x`/`y`/`width`/`height`) or `image_path`. The main display is used if you give none.

| Argument | Type | Default | |
|---|---|---|---|
| *target* | see above | main display | |
| `image_path` | string | | OCR a local image file instead of the screen. `~` is expanded. |
| `languages` | string[] | `["zh-Hans", "en-US"]` | Vision language codes in priority order. |
| `recognition_level` | `accurate` \| `fast` | `accurate` | |
| `min_confidence` | number 0–1 | `0` | Drop lines below this confidence. |
| `include_boxes` | boolean | `true` | Return per-line boxes as JSON. |
| `include_image` | boolean | `false` | Also return the captured image. |
| `max_dimension` | integer | `1568` | For the returned image. |

The result contains the recognized text (one line per row) and, as JSON, each line's `text`, `confidence`, `screen_box` (global points; only for screen captures), `pixel_box` (image pixels, top-left origin) and `normalized_box` (0–1, top-left origin).

### `annotate_screen`

*Needs the Inkpane app.* Draws marks on the user's screen in a click-through overlay and returns their ids. Marks fade out after `ttl_seconds`.

| Argument | Type | Default | |
|---|---|---|---|
| `annotations` | object[] (required) | | 1 to 100 marks; see below. |
| `ttl_seconds` | number | `10` | Lifetime of each mark, fade included. `0` keeps marks until `clear_annotations`. |
| `replace` | boolean | `false` | Remove your previous marks first. |
| `window_id` | integer | | Stick the marks to this window (from `list_windows`). Coordinates are then relative to the top-left corner of the window's frame. See below. |

Each mark has a `type` and the fields for it, all in global screen points (or window points with `window_id`):

| `type` | Fields | |
|---|---|---|
| `box` | `x`, `y`, `width`, `height` | Rectangle outline. |
| `highlight` | `x`, `y`, `width`, `height` | Translucent marker stroke over the rectangle (yellow by default). |
| `arrow` | `from_x`, `from_y`, `to_x`, `to_y` | The head is at `to`. |
| `text` | `x`, `y`, `text` | Top-left corner at `x`/`y`, on a dark plate. |
| `spotlight` | `x`, `y`, `width`, `height` | Dims the rest of the display(s) the rectangle is on and leaves it clear. Optional `shape` (`rectangle` or `ellipse`) and `dim_opacity` (0.1–0.9, default 0.55). |

Optional on every mark: `color` (`#RRGGBB`, `#RRGGBBAA` or `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `white`, `black`), `line_width` (not for spotlights), `font_size` and `ttl_seconds`. Boxes, highlights, arrows and spotlights also take a `label`: a caption drawn above the box (or below it at the top of the screen), or beside an arrow's tail. A spotlight's `color` is its label's plate (default black). The result lists one `id` per mark, plus the `label_id` of its caption.

Spotlights combine: several of them leave several clear areas in one dim layer (overlapping ones merge), the darkest `dim_opacity` wins, and your other marks are drawn above the dimming at full strength. Displays no spotlight touches aren't dimmed. When spotlights with different lifetimes overlap, the one that ends first closes its hole and the dimming goes away with the last one. In a `record_action` recording the dimming is recorded like any other mark.

```json
{"annotations": [
  {"type": "box", "x": 220, "y": 140, "width": 180, "height": 44, "label": "This button"},
  {"type": "arrow", "from_x": 600, "from_y": 300, "to_x": 410, "to_y": 165, "color": "blue"}
], "ttl_seconds": 15}
```

```json
{"annotations": [
  {"type": "spotlight", "x": 200, "y": 120, "width": 240, "height": 90, "shape": "ellipse", "label": "Watch this"}
], "ttl_seconds": 8}
```

**Marks that stick to a window.** With `window_id`, every coordinate is in points from the top-left corner of that window's frame (`x: 0, y: 0` is the corner of the `frame` `list_windows` reports, title bar included). The marks then follow the window: they move with it, also onto another display, and keep their size and offset from the top-left corner when it is resized (they aren't scaled). They are hidden while the window is minimized, on another Space, its app is hidden or it is entirely covered, and the parts under other windows are clipped. When the window closes they are removed (after a two-second grace period in which a re-created window of the same app with the same title takes them over). They don't follow content scrolled inside the window. The app refuses a `window_id` that doesn't exist (`invalid_request`) or belongs to an app on the user's exclusion list or to Inkpane (`excluded`), before drawing or replacing anything. The result has a `window` object (`window_id`, `app_name`, `title`, `frame`, `is_on_screen`); `is_on_screen: false` means the marks appear once the window is shown. A Inkpane app from before `window_id` would ignore it, so `inkpane-mcp` removes those marks again and reports an error asking to update the app.

```json
{"window_id": 4021, "annotations": [
  {"type": "box", "x": 24, "y": 96, "width": 180, "height": 32, "label": "Fill this in"}
], "ttl_seconds": 0}
```

### `clear_annotations`

*Needs the Inkpane app.* Removes the marks with the given `ids` (their labels go with them), or every mark the agent drew when `ids` is omitted. The user's own drawings stay unless `include_user` is `true`. Returns how many were removed.

### `wait_for_user_annotation`

*Needs the Inkpane app.* The reverse channel: shows the user a banner with your `prompt` and waits while they drag a rectangle (or draw a freehand outline) on screen. Return or **Send** confirms; Esc or **Cancel** cancels. R and F switch between rectangle and freehand.

| Argument | Type | Default | |
|---|---|---|---|
| `prompt` | string (required) | | Shown in the banner, e.g. `"Circle the broken button"`. Up to 500 characters. |
| `shape` | `rectangle` \| `freehand` | `rectangle` | The tool the user starts with; they can switch. |
| `timeout_seconds` | number | `120` | Up to 3600. |
| `include_image` | boolean | `true` | Return a screenshot of the region. |
| `include_ocr` | boolean | `true` | Return the text recognized in the region. |
| `languages` | string[] | `["zh-Hans", "en-US"]` | OCR languages. |
| `max_dimension` | integer | `1568` | For the returned image. |

When the user confirms, the result has the recognized text, JSON metadata and the image. The metadata holds `status: "selected"`, `region` (`shape`, `bbox` in global points, the freehand `points` and `display_index`), the saved `path`, `frame`, `points_per_returned_pixel` and `ocr` (`text` plus `lines` with `screen_box`). The screenshot leaves out Inkpane's own overlay, so your annotations don't cover the content. If the app can't capture (it lacks Screen Recording permission), `inkpane-mcp` captures the region itself and says so in `note`.

When the user doesn't select anything, the result is not an error: `status` is `"cancelled"` (with `reason`: `user`, `dismissed` when the overlay was closed, or `superseded` by a newer request) or `"timed_out"`. If your MCP client cancels the call, the banner goes away.

MCP clients have their own tool-call timeouts. Keep `timeout_seconds` below your client's limit.

### `record_action`

*Needs the Inkpane app.* Records the user's screen to an MP4 (H.264, or HEVC above 4096 pixels) in the app's captures folder, for bug reports and demos. Your `annotate_screen` marks and the user's own drawings are recorded ("burned in"); Inkpane's toolbar and recording controls are not. While recording, the app shows its recording panel (timer, pause, draw, stop), so the user always knows and can stop it. The recording also appears in the app's Library.

| Argument | Type | Default | |
|---|---|---|---|
| `action` | `start` \| `stop` \| `status` (required) | | |
| `target` | `display` \| `window` \| `region` | `display` | *start.* Inferred from `window_id`/`app` or `x`/`y`/`width`/`height` when omitted. |
| `display` | integer | `0` | *start.* Display index from `list_windows`. |
| `window_id` / `app` + `title` | | | *start.* Records the window's area as it is when the recording starts (anything on top of it is recorded too, including annotations). |
| `x`, `y`, `width`, `height` | number | | *start.* A region in global points, at least 16×16. |
| `fps` | integer | the app's setting (30) | *start.* 1–60. |
| `show_clicks` | boolean | the app's setting | *start.* Highlight mouse clicks. |
| `show_keys` | boolean | the app's setting | *start.* Show pressed keys. Needs Accessibility permission for the app; without it the result has a `note` and keys aren't shown. |
| `show_cursor` | boolean | the app's setting | *start.* |
| `max_duration_seconds` | number | `300` | *start.* Stops by itself after this long (at most 3600). |
| `microphone` | boolean | the app's setting | *start.* Record the microphone. macOS 15+ and Microphone permission for the app; otherwise the recording goes ahead without it and the result has a `note`. The app never shows the permission prompt for an agent's recording. |
| `system_audio` | boolean | the app's setting | *start.* Record what the Mac plays, without Inkpane's own sounds. macOS 15+; on macOS 14 it is ignored with a `note`. |
| `recording_id` | string | the current one | *stop.* |
| `gif` | boolean | `false` | *stop.* Also export an animated GIF next to the MP4. |
| `gif_fps`, `gif_width` | integer | `10`, `720` | *stop, with `gif`.* |

`start` returns `recording_id`, the recorded `frame` in global points, the movie's `pixel_width`/`pixel_height`, `fps` and the effective `show_clicks`/`show_keys`/`microphone`/`system_audio` (an app from before sound returns neither and ignores the options; the tool then says the recording is silent). `stop` returns `path`, `duration` (seconds, without paused stretches), the pixel size, `frame_count`, `ended_by` (`agent`, `user` when the user pressed Stop first, `max_duration`, or `error` when capture stopped early, e.g. a display was disconnected), `gif_path` and `audio` (`microphone`, `system_audio`: what can be heard; the MP4 has one AAC track with both mixed, kept in step with the video across pauses; GIFs have no sound). Recordings you start are always burned in. If you stop one the user started while their app is set to "Annotations: Editable track", `stop` also returns `annotations_editable: true` and `annotations_path`, a JSON sidecar next to the MP4 that holds the marks, which the MP4 then doesn't show; the user edits them and exports a version with or without them in the app. If the recording already ended, `stop` still returns its file. `status` returns `state` (`idle`, `recording` or `paused`) and `elapsed`. Only one recording runs at a time; `start` fails while one is running. The app needs Screen Recording permission.

### `capture_scrolling`

*Needs the Inkpane app, Inkpane Pro and Accessibility permission for the app.* Captures a window or region that scrolls (a long web page, chat, document or list) as one long image. The app scrolls it automatically from where it is now to the end (it only scrolls down, so scroll the content to the starting point first) and stitches the frames, with its usual scrolling-capture border and controls on screen. The user confirms every call in a prompt, and can take over by touching the mouse or trackpad (then the capture ends when they click Done) or cancel it. With a window, the app brings it to the front and captures the scrolling area at its centre when Accessibility finds one (a list or page without the window's sidebar and toolbar), otherwise the whole window. Excluded apps' windows are left out of the frames, and the user's redaction settings are applied to the whole image.

| Argument | Type | Default | |
|---|---|---|---|
| `window_id` / `app` + `title` | | | The window to scroll. |
| `x`, `y`, `width`, `height` | number | | Or a region in global points, at least 16×16. |
| `include_image` | boolean | `true` | Return the image slices. |
| `include_ocr` | boolean | `false` | Also return the text of the whole image (recognized in overlapping bands, each line once). |
| `languages` | string array | | With `include_ocr`. |
| `slice_width` | integer | `1280` | Width of the returned slices (200–4000; never scaled up). |
| `max_slices` | integer | `6` | Return at most this many slices from the top (1–20). |
| `max_height` | integer | `30000` | Stop once the image is this many pixels tall (100–30000). |
| `max_duration_seconds` | number | `90` | Stop scrolling after this long (5–300) and return what was captured. |

The image is returned in slices from top to bottom, at most 1568 pixels tall each and overlapping by about 48 pixels, because one image of a long page would be scaled down until its text is unreadable; the full-size PNG is saved in the output folder. The JSON has `path`, `frame` (the scrolled area), `scale`, `pixel_width`/`pixel_height`, `window`, `ended_by` (`bottom`, `limit`, `timeout`, `unsupported` when the app didn't scroll for synthetic events and the image is only what was visible, `user`, or `lost` when the stitching lost its place and couldn't find it again, so the image stops there), `slices` (each slice's `y` and `height` in the full image's pixels), `privacy` and `note` (for example when the stitching lost its place because the content changed while scrolling, so the end is missing). It fails with `denied` when the user says no or cancels, and with an explanation when Accessibility is missing (the app then asks the user for it) or the app is too old.

### When the app isn't running

The tools above return an error that starts with *"Inkpane app is not running"*, tells the user how to start it, and says that `capture_screen`, `capture_window`, `capture_region`, `read_screen_ocr` and `list_windows` work without it (unless you run with `--require-app`).

### `list_windows`

List windows front to back, with the active displays.

| Argument | Type | Default | |
|---|---|---|---|
| `app` | string | | Only this app (name or bundle id). |
| `include_offscreen` | boolean | `false` | Include minimized, hidden and other-Space windows. |
| `include_system` | boolean | `false` | Include non-zero window layers (menu bar, Dock, status items, overlays). |

Each window has `window_id`, `app_name`, `bundle_id`, `pid`, `title`, `frame`, `layer`, `is_on_screen`, `z_order` (lower means closer to the front), `alpha` and `display_index`. Each display has `index`, `display_id`, `frame`, `pixel_width`, `pixel_height`, `scale` and `is_main`. `frontmost_window_id` is the frontmost normal window.

### `get_ui_tree`

The Accessibility tree of a window, so an agent can name a control exactly (*"the `AXButton` with identifier `save` is disabled"*) instead of guessing from pixels. Needs Accessibility permission (see [Permissions](#permissions)).

| Argument | Type | Default | |
|---|---|---|---|
| `window_id` / `app` + `title` | | the frontmost window | Which window. Inkpane's own windows are never "the frontmost window". |
| `roles` | string[] | | Only elements with one of these roles or subroles (`AXButton`, or just `button`). |
| `text` | string | | Only elements whose title, label, value, help, placeholder or identifier contains this text (case-insensitive). |
| `max_depth` | integer | `15` | Levels below the window (at most 60). |
| `max_nodes` | integer | `500` | Elements read, at most (up to 5000). The walk is breadth first, so the top of the tree is complete. |
| `max_text_length` | integer | `200` | Longer titles, labels and values are cut (8–2000). |
| `time_limit_seconds` | number | `3` | Stop reading after this long (0.1–15). Every AX read is a call into the other app. |
| `format` | `json` \| `outline` | `json` | `outline` is one indented line per element, much shorter. |

Each element has `role`, `subrole`, `title`, `label` (`AXDescription`), `value` (as text: field contents, `0`/`1` for checkboxes, …), `help`, `placeholder`, `identifier` (`AXIdentifier`), `enabled`, `focused` and `selected` (only when true), `frame` in global screen points, and `children`. `omitted_children` counts children a limit kept from being read; the result's `limits_hit` names the limits (`max_depth`, `max_nodes`, `time_limit`) and `node_count` how many elements were read. With `roles` or `text`, the result is a flat `matches` list instead of a tree, each match with its `path` (e.g. `AXWindow "Settings" > AXGroup > AXTabGroup`).

Privacy: password fields (`AXSecureTextField`) are marked `secure` and **never** return their value, whatever the settings. With the app running, excluded apps are refused (also when they are the frontmost window), and with auto-redaction on, email addresses and phone numbers in any text are replaced by `[email]` / `[phone]`. Filters match the redacted text, so they can't probe for hidden values. Without the app, `INKPANE_MCP_EXCLUDE_APPS` applies.

```json
{"roles": ["AXButton"], "app": "Simulator", "format": "outline"}
```

### `diff_screenshots`

What changed between two screenshots: for visual regression checks, or to see what an action did.

| Argument | Type | Default | |
|---|---|---|---|
| `before` | string (required) | | An image file path (e.g. the `path` of an earlier capture) or `screen://assets/{id}` (*needs the app*). |
| `after` | string | capture now | The same kinds. Omit it to compare `before` with a capture taken now, chosen like `capture_*`: `display`, `window_id`, `app` + `title`, or `x`/`y`/`width`/`height` (default the main display). The capture goes through the app's privacy rules and is saved, so it can be the next `before`. |
| `frame` | `{x, y, width, height}` | the capture's frame | The screen area (global points) both images show, so boxes also come in screen points. |
| `threshold` | number 0–1 | `0.1` | How much a colour channel must differ for a pixel to count as changed. `0` counts every difference. |
| `include_image` | boolean | `true` | Return the difference image (it is always saved). |
| `max_dimension` | integer | `1568` | For the returned difference image. |
| `annotate` | boolean | `false` | Draw the changed regions on the user's screen with `annotate_screen` (*needs the app* and screen coordinates). |
| `ttl_seconds` | number | `10` | With `annotate`. |

The result has `changed_percent`, `changed_pixels`, `regions` (largest first, at most 50; `omitted_regions` counts the rest), each with `pixel_box`, `changed_pixels` and, when the screen area is known, `screen_box`; `compared_width`/`compared_height`; `diff_path`; and with `annotate`, `annotation_ids`. The difference image is the newer image faded, with changed pixels in red and each region outlined.

How it compares: a pixel changed when any channel differs by more than `threshold`, which ignores anti-aliasing and compression noise; nearby changes (within 8 pixels) are merged into one region, and regions of fewer than 4 changed pixels are dropped as noise. Images with the same aspect ratio but a different resolution (a Retina and a non-Retina capture of the same area) are compared at the smaller size; other size differences are an error that says so.

## Resources

| URI | |
|---|---|
| `screen://windows/active` | JSON: on-screen normal windows front to back, `frontmost_window`, displays and permission status. |
| `screen://assets/recent` | *Needs the Inkpane app.* JSON: the 20 newest captures in the Inkpane library, each with `id`, `path`, `kind`, `created` (ISO 8601), `app_name`, `bundle_id`, `window_title`, `url`, `kept_forever` (in a group, or kept forever by a rule, so never cleaned up automatically; older apps sent `pinned`), `pixel_width`/`pixel_height`, `ocr_snippet` (the first 200 characters of its recognized text) and, for captures of code editors and terminals, `project`, `branch`, `repo` (the `origin` URL without credentials) and `repo_path` (the repository root). These four are omitted when unknown, and apps from before they were added never send them. Captures of excluded apps are left out. |
| `screen://assets/{id}` | *Needs the Inkpane app* (a resource template). The capture as a PNG (longer edge at most 1568 px), plus its metadata as JSON. |

## Prompts

MCP prompts are ready-made instructions a client can offer as commands (in Claude Code: `/mcp__inkpane__report_ui_bug`). Both arguments lists are optional.

| Prompt | Arguments | What it has the agent do |
|---|---|---|
| `report_ui_bug` | `app`, `expected`, `steps` | Ask you to circle the problem (`wait_for_user_annotation`), capture the window, read the elements involved (`get_ui_tree`, or OCR without Accessibility), then write a Markdown bug report: title, environment, steps to reproduce (only steps it knows; inferred ones are marked), expected and actual behaviour, evidence (screenshot paths, coordinates, element roles and identifiers). |
| `explain_error_on_screen` | `app`, `language` | Read the frontmost window (or `app`'s) with OCR and, for dialogs, `get_ui_tree`; quote the error, explain the likely cause and fixes, and point at it with `annotate_screen`. |

## With or without the Inkpane app

`inkpane-mcp` is a complete, standalone MCP server: everything above except `annotate_screen`, `clear_annotations`, `wait_for_user_annotation` and `screen://assets` works without the Inkpane app. When the app *is* running, this is what changes:

- **Screen reads go through the app.** `capture_screen`, `capture_window`, `capture_region`, `read_screen_ocr` (except with `image_path`), `list_windows` (and `screen://windows/active`), `get_ui_tree` and the capture `diff_screenshots` takes are sent to the app over its socket instead of running in this process. The app:
  - **asks you first.** The first time an agent connects, the app shows who is asking (the MCP client's name and version, the program that launched `inkpane-mcp` and its pid, and the app it runs in) with **Deny**, **Allow Once** (until that agent session ends) and **Always Allow** (remembered; revoke it in Inkpane Settings → Privacy). Until you answer, the call waits (up to two minutes).
  - **leaves out excluded apps.** Password managers, banking and finance apps and messaging apps (1Password, Bitwarden, Keychain Access, Passwords, Messages, WeChat, Telegram, Signal, Slack, WhatsApp, …) are excluded by default; the list is editable. Their windows are filtered out of screen and region captures and OCR, omitted from `list_windows`, and `capture_window` on them fails with an error that says so.
  - **can black out personal data** (off by default): email addresses and phone numbers found by OCR, and password fields (with Accessibility permission), in images and recognized text.
  - **shows that an agent is looking**: a small pill at the top of the screen and an eye in the menu bar, for about two seconds after each capture, OCR, selection or annotation. The pill never appears in captures.
  - **keeps a local log** of agent requests (time, agent, tool, decision), viewable in Settings → Privacy.
- The result says what was hidden, for example *"Privacy: windows of Slack were left out (excluded by the user); 1 email address(es) blacked out."*
- If the app itself can't capture (it lacks Screen Recording permission), it answers with its privacy rules and `inkpane-mcp` captures in its own process **under those rules**: same exclusions, same redaction. The result's `note` says so. `get_ui_tree` works the same way when the app lacks Accessibility permission.
- A refusal is final. When you deny an agent, or it asks for an excluded app, `inkpane-mcp` returns the error; it never falls back to capturing by itself.
- **No app (nothing listens on the socket), or an older app** that doesn't know these requests: `inkpane-mcp` captures by itself exactly as without the app. No prompt, no exclusion list (unless you set `INKPANE_MCP_EXCLUDE_APPS`), no redaction, no indicator.

To make sure the app's protections always apply, start the server with **`--require-app`** (or set `INKPANE_MCP_REQUIRE_APP=1`). Screen reads then fail with an explanation whenever the app isn't running:

```bash
claude mcp add inkpane -- /absolute/path/to/inkpane-mcp --require-app
```

What this protects against: an agent that only uses MCP tools sees your screen only after you said yes, never sees excluded apps, and can't silently look. It is not a sandbox: `inkpane-mcp` runs as you, and an agent that can run arbitrary shell commands could take a screenshot some other way (for example with `screencapture`) if its terminal has Screen Recording permission.

## Configuration

| Environment variable | |
|---|---|
| `INKPANE_MCP_OUTPUT_DIR` | Where captures are saved. Default: `$TMPDIR/inkpane-mcp`. |
| `INKPANE_APP_DIR` | Folder holding the Inkpane app's `agent.sock` and `agent.token`, and the `--http` token `mcp-http.token`. Default: `~/Library/Application Support/app.inkpane.Inkpane` (for the `inkpane-mcp` inside an Inkpane app, that app's own folder, e.g. `app.inkpane.Inkpane.debug` for a development build). |
| `INKPANE_MCP_REQUIRE_APP` | `1` does the same as `--require-app`: screen reads fail unless the Inkpane app is running. |
| `INKPANE_MCP_EXCLUDE_APPS` | Comma-separated bundle ids to leave out of captures and window lists when the app is **not** running (e.g. `com.1password.1password,com.tinyspeck.slackmacgap`). With the app running, its own list applies. |

## Talking to the Inkpane app

`annotate_screen`, `clear_annotations`, `wait_for_user_annotation`, `record_action`, `capture_scrolling`, the library resources and (while the app runs) all screen reads are forwarded to the Inkpane menu bar app over a Unix domain socket. The protocol types and the client are open source, in `InkpaneKit` (`Sources/InkpaneKit/Bridge/`). This package doesn't depend on the app's code.

- **Discovery.** The app listens on `~/Library/Application Support/app.inkpane.Inkpane/agent.sock`. That folder is named after the app's bundle identifier.
- **Access.** The socket is mode `0600`. The app refuses connections from other users, and writes a random per-launch token to `agent.token` (also `0600`) next to the socket. Every request carries the token, so only your own processes can draw on your screen or ask you for a selection.
- **Framing.** Newline-delimited JSON with snake_case keys. Each request has a protocol version `v`, an `id`, the `token`, a `method` and `params`, plus `client`: the MCP client's `name`, `title` and `version` from its `initialize` request, and `via` (`inkpane-mcp 0.9.0`). Each response repeats the `id` and carries `ok`, plus a `result` or an `error` with a `code` and a `message`. Unknown codes from a newer app read as `failed`.
- **Methods.** `hello`, `annotate` (mark kinds `box`, `arrow`, `text`, `highlight` and `spotlight`, the last with optional `shape` and `dim_opacity`; an app from before `spotlight` answers `invalid_request` for it, still under protocol version 1; optional `window_id` pins the marks to a window and the result then carries `window`, and an app from before it ignores the field), `clear`, `wait_for_user_annotation`, `authorize`, `record_start`, `record_stop`, `record_status` (see `BridgeRecording.swift`), `capture_scrolling` (a window or region target, optional OCR, `max_height`, `max_duration`; the app writes the PNG to `AgentScrolling/` in its folder and returns its `path`, which the caller takes over; see `BridgeScrolling.swift`), `capture` (a target and optional OCR settings; returns a full-resolution PNG, OCR and a privacy report, or a `fallback` with the policy to capture under), `list_windows`, `recent_assets`, `asset` and `ui_tree` (a target and `UITreeOptions`; returns the tree, or a `fallback` with the policy to read it under, like `capture`; an older app answers `unknown_method` and `inkpane-mcp` reads the tree itself). The types are in `BridgeProtocol.swift`, `BridgeScreenProtocol.swift` and `BridgeUITree.swift`.
- **Authorization.** Every method except `hello` and `authorize` needs an allowed client. Otherwise the app answers `authorization_required`; the client then sends `authorize` (the app shows its prompt) and, if allowed, repeats the request. `BridgeClient` does this for you. `denied` means the user said no for this session; `excluded` means the target belongs to an excluded app. The app identifies the connecting process itself (`LOCAL_PEERPID`, its parent and its `.app`), so `client` is only a label.

```
→ {"v":1,"id":"1","token":"…","method":"annotate","params":{"annotations":[{"kind":"box","rect":{"x":10,"y":10,"width":80,"height":40}}],"ttl":5}}
← {"v":1,"id":"1","ok":true,"result":{"ids":["…"],"items":[{"id":"…","ttl":5}]}}
```

`inkpane-mcp` opens one connection per call. Closing the connection withdraws a pending `wait_for_user_annotation`.

## Using `InkpaneKit` directly

```swift
.package(url: "<this repo>", from: "0.9.0")
// target dependency: .product(name: "InkpaneKit", package: "inkpane-mcp")
```

```swift
import InkpaneKit

let windows = WindowList.windows()
let capture = try await ScreenCapturer().capture(.app("Safari", titleContains: nil))
let text = try TextRecognizer().recognize(capture.image, captureFrame: capture.frame)
for line in text.lines { print(line.text, line.screenBox ?? line.pixelBox) }

// What changed, and the Accessibility tree (needs Accessibility permission):
let diff = try ImageDiff.compare(before, after)   // diff.regions, diff.changedPercent
let tree = try UITreeReader().read(.frontmost, options: UITreeOptions(roles: ["AXButton"]))

// With the Inkpane app running:
let bridge = BridgeClient()
_ = try await bridge.annotate(AnnotateParams(annotations: [.box(Rect(x: 100, y: 100, width: 300, height: 120), label: "Here")]))
let answer = try await bridge.waitForUserAnnotation(UserAnnotationParams(prompt: "Circle the broken button"))
```

## Privacy

`inkpane-mcp` runs only on your machine and makes no network requests. Its only other connection is the local Unix socket to the Inkpane app; with `--http` it also listens on `127.0.0.1` (see [Over HTTP](#over-http-streamable-http)). With the app running, the app decides what agents may see (see [With or without the Inkpane app](#with-or-without-the-inkpane-app)); without it, use `INKPANE_MCP_EXCLUDE_APPS` to keep apps out of captures. Screenshots go to the MCP client that asked for them (and from there to whatever model that client uses) and to the local output directory. Only connect it to agents you trust with what's on your screen.

## License

MIT. See [LICENSE](LICENSE).
