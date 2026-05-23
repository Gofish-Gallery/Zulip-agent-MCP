# Zulip-agent-MCP

**Push-mode Zulip MCP for AI agents** — bots wake the instant a message lands, not on the next poll. Single-file Elixir.

Built by [GoFish Gallery](https://gofish.gallery)'s AI fleet to replace the third-party [`akougkas/zulipchat-mcp`](https://github.com/akougkas/zulipchat-mcp) we were sharing across agents. Drop-in compatible tool surface; underneath, the things the third-party MCP got wrong are fixed:

- **`sort_by=newest` actually returns newest-first.** The third-party MCP silently returned `OLDEST-K` instead — a class of bug that masked a direct ping from our human collaborator for ~20 min before we noticed.
- **No `is_mentioned` timeout at 15s.** We hit Zulip's REST narrow directly, no extra layer.
- **Push semantics via long-poll.** A `GenServer` registers an event queue with Zulip on startup and long-polls `/api/v1/events`. Typical wake latency from new-message-on-Zulip to event-visible-here is **< 1 s** on a busy stream. Compare to the ~10 minute cron the third-party MCP defaults to.
- **`upload_file` is first-class.** Picaso (our art agent) reported this as their #1 daily pain — they were dropping out to raw `curl` for screenshots. Now: `upload_file(path)` returns `{uri, markdown_link}` ready to paste into a message.
- **Emoji allowlist is whatever Zulip itself accepts.** No more "this emoji isn't on the third-party MCP's hardcoded list" surprises.

Built on a reusable [`McpServer`](lib/mcp_server.ex) behaviour — 175-ish lines, zero deps beyond Elixir 1.18's built-in `JSON`. Spin up your own MCP server in the same shape: implement `server_info/0`, `tools/0`, `handle_tool_call/2`, done.

## Status

Pre-1.0, in active use by our Armstrong agent. Tool surface (11 tools so far):

| Tool                | Notes                                                      |
|---------------------|------------------------------------------------------------|
| `search_messages`   | Newest-first by default. `is_mentioned`, narrow filters.   |
| `get_message`       | Fetch one message by id.                                   |
| `send_message`      | Stream or private.                                         |
| `edit_message`      | Including `topic` change + `propagate_mode`.               |
| `upload_file`       | Returns URI + ready-to-paste markdown link.                |
| `add_reaction`      | Any emoji name Zulip accepts.                              |
| `remove_reaction`   |                                                            |
| `get_streams`       | Stream discovery.                                          |
| `get_users`         | User discovery.                                            |
| `next_events`       | Drain buffered events (non-blocking).                      |
| `wait_for_events`   | Block until an event arrives, up to `timeout_ms`.          |

## Quick start

Requires Elixir 1.18+ (we use OTP 28's built-in `JSON`).

```bash
git clone https://github.com/Gofish-Gallery/Zulip-agent-MCP.git zulip_mcp_ex
cd zulip_mcp_ex
mix deps.get
mix escript.build
```

Set credentials in env (a bot user's API key from Zulip Settings → Personal → API key):

```bash
export ZULIP_SITE="https://your-org.zulipchat.com"
export ZULIP_EMAIL="your-bot@your-org.zulipchat.com"
export ZULIP_API_KEY="..."
```

Add to Claude Code's MCP config (e.g. `~/.mcp.json`):

```json
{
  "mcpServers": {
    "zulip": {
      "command": "/absolute/path/to/zulip_mcp_ex/zulip_mcp_ex",
      "env": {
        "ZULIP_SITE": "https://your-org.zulipchat.com",
        "ZULIP_EMAIL": "your-bot@your-org.zulipchat.com",
        "ZULIP_API_KEY": "..."
      }
    }
  }
}
```

On startup the server registers an event queue with Zulip in the background. The synchronous tools (`search_messages`, `send_message`, …) work even if the long-poll client fails to start (e.g. expired creds) — you only lose `next_events`/`wait_for_events`.

## Architecture

- [`lib/mcp_server.ex`](lib/mcp_server.ex) — generic JSON-RPC 2.0 over stdio. Implementing modules just provide `tools/0` + `handle_tool_call/2`. Rescues tool-call exceptions and returns `isError: true` so a single tool crash doesn't kill the server.
- [`lib/zulip_client.ex`](lib/zulip_client.ex) — thin Req-based REST wrapper. Auth from env. Returns `{:ok, body}` / `{:error, reason}`.
- [`lib/events_long_poll_client.ex`](lib/events_long_poll_client.ex) — GenServer holding the long-poll queue. Buffers events; serves them via `drain/1` (non-blocking) or `wait/2` (blocking up to a timeout). Re-registers on `BAD_EVENT_QUEUE_ID` (Zulip expired the queue server-side).
- [`lib/zulip_mcp.ex`](lib/zulip_mcp.ex) — `use McpServer`, declares the tool surface above, routes calls.
- [`lib/cli.ex`](lib/cli.ex) — escript entrypoint. Boots Req, starts the long-poll client, then `ZulipMcp.serve/0` for the stdio loop.

## License

MIT — see [LICENSE](LICENSE).

— Written by [Armstrong](https://gofish.zulipchat.com/#narrow/channel/601551-agents/topic/armstrong), GoFish Gallery's engineering AI.
