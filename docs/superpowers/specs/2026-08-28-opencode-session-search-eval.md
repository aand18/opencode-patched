# Eval: giving the opencode agent a fast way to search past sessions

Date: 2026-08-28
Status: eval — ready for review
Context: user wants an easy, fast, low-maintenance way for the agent itself to search through past opencode sessions, as a crutch for short context and frequent compaction. Prefers off-the-shelf over building. Okay with a vector database if it gives granular, detailed results. Does NOT want to have to tell the agent "please remember this" — indexing should happen automatically in the background. User knows `llama-server` but not opencode internals or vector-database jargon, so this doc avoids jargon or explains it.

## 1. The problem in plain language

Opencode is the AI coding assistant you run locally. Every conversation you have — your questions, the agent's answers, the code edits it made, the tool calls — gets saved automatically.

The agent itself has a small working memory. As a conversation gets long, opencode "compacts" it: it summarizes or drops older parts so the next prompt still fits. That is necessary, but it means the agent forgets details you may need later: which file you patched last week, why you chose a certain flag, the exact error message from a previous run.

Today the agent has tools like `read` (read a file), `grep` (search files on disk), and `glob` (list files). It has **no tool** that says "search what we talked about in past sessions." If you want it to find something from an old session, you have to remember which session it was and paste it back in. The idea here is to give it that missing tool — and make it work without you having to remember to save anything.

## 2. How opencode saves sessions today (no jargon)

You do not need to know code to understand this, but it helps the eval:

*   All sessions live in **one local SQLite file** on your machine, usually at `~/.local/share/opencode/opencode.db`. SQLite is just a single file that acts like a tiny database — no server to run, no separate process, just a file on disk.
*   Inside that file there are three tables that matter:
    *   `session` — one row per conversation, with title, project, timestamps
    *   `message` — the turns inside that conversation (user messages and assistant messages)
    *   `part` — the actual content inside each message (text, thinking, patches, tool results)
*   The code that defines these tables is at `packages/core/src/session/sql.ts:22` (SessionTable), `:68` (MessageTable), `:82` (PartTable), and the code that lists sessions is at `packages/opencode/src/session/session.ts:552`.

That means **all your history is already on disk**, locally, in one place. Anything we add only needs to *read* that file — it does not need to ask an external service where your history is.

## 3. What a "vector database" means, explained simply

Normal search (keyword search) only finds exact words. If you search for `layout toggle`, it will not find a session that says `newLayoutDesigns flag`.

A vector database fixes that by turning each piece of text into a list of numbers (called an "embedding" — think of it as a fingerprint for meaning). Texts with similar meaning get similar fingerprints, even if the words differ. Searching becomes "find fingerprints close to the query fingerprint," which means you can search by idea, not just by exact word.

A few extra terms, explained once:

*   **Embedding model** — the program that turns text into those numbers. Small models are ~30 MB and run on your normal CPU (no graphics card needed). Larger models are more accurate but heavier. You run this model once per chunk of text, it takes a few milliseconds.
*   **Vector search vs keyword search** — vector finds meaning, keyword finds exact words. The best systems do both at once ("hybrid") and merge the results, because sometimes you need exact (`--no-verify` flag) and sometimes meaning ("the VCS crash").
*   **`llama-server`** — a program you already know. It can run an embedding model and answer requests like "turn this text into numbers" over `http://localhost:8081`. Some of the options below use `llama-server`, others just run a tiny model directly inside opencode itself (using a library called `@huggingface/transformers` with ONNX — same idea, just no separate server, it runs inside the same process on CPU).
*   **Sidecar database** — a second small file next to your main `opencode.db` that stores the fingerprints. Your original history stays untouched; the sidecar is just a fast index that can be rebuilt or deleted.

**VRAM note:** You said you do not want to use VRAM (graphics card memory). All "local CPU" options below use 0 VRAM. Only the `llama-server` option in one package needs your graphics card to stay running; the others do not.

## 4. What "auto-index, no prompting" means

You said you do not want to have to tell the agent "remember this." The ideal behavior is:

1.  You just work normally — ask questions, let the agent edit code.
2.  When a turn finishes (you asked, agent answered), something in the background wakes up, reads that new turn from the SQLite file, splits it into chunks, turns each chunk into a fingerprint, and adds it to the sidecar file.
3.  No prompt from you, no extra tool call from the agent. It just happens.

All the mature options do this, but in two different styles:

*   **Raw chunks:** Take your actual messages verbatim, split them (e.g., one chunk per turn), fingerprint those. Most granular — you get exact text, exact code patches, exact error strings back.
*   **Summarized notes:** Run a second, cheap AI call to write 2–6 bullet points summarizing the turn ("fixed VCS crash by switching `--untracked-files` flag, added filter"), then fingerprint the bullets. Smaller index, human-readable notes, but you lose detail. Some also keep a way to jump back to the raw transcript if you need detail — that is the "3-layer" pattern: search → show snippet → expand to full text → open original transcript.

For your stated goal ("granular enough data is worth keeping a vector database"), raw chunks are the better fit. Summaries are lossy for code.

## 5. Options that already exist

I checked the opencode ecosystem and broader community. Everything below reads the same `opencode.db` you already have. None of them send your history away unless you configure a cloud key.

### Option 1: tickernelz/opencode-mem — the most popular, lowest hassle

*   What it is: An opencode plugin (TypeScript, runs inside Bun, the same runtime opencode uses). 1.6k stars, actively maintained, works on Linux/macOS/Windows.
*   Vector storage: Built-in Turso/libSQL — which is just SQLite with a built-in way to store fingerprints and search them fast. One file in `~/.opencode-mem/data`. No separate server.
*   Embeddings: Tiny model that runs directly inside Bun on CPU via `@huggingface/transformers` + ONNX. Default `nomic-embed-text-v1` (768 numbers) or you can pick `all-MiniLM-L6-v2` (384 numbers, faster). After first download (~30 MB) it needs no internet, no API key, 0 VRAM.
*   Auto-index: Yes. When your session goes idle, a background AI call (using whatever provider you already use in opencode — e.g., Anthropic Haiku, via `opencodeProvider` + `opencodeModel: "inherit"`) extracts "memorable technical context" and saves it. You do nothing. Search without that provider still works; only the automatic note-taking needs it.
*   What the agent gets: A tool called `memory` with modes like `search` ("find architecture decisions"), `add` (manual if you want), `list`, `profile`. Also automatic injection: before compaction or at the start of a new chat, it injects the top 3–10 relevant memories so the agent has context without you asking.
*   Granularity: **Summarized**. You get bullets, not full turns. Good for "why did we choose X?" but not for "show me the exact patch from last Tuesday."
*   Maintenance: Very low. Install is one line in `~/.config/opencode/opencode.json`: `"plugin": ["opencode-mem"]`, restart. Config file `~/.config/opencode/opencode-mem.jsonc` is auto-created with comments. Web UI at `http://127.0.0.1:4747` if you want to browse.
*   Downside for your goal: Not granular enough if you need exact code/patches after compaction.

### Option 2: memsearch family (@zilliz/memsearch-opencode, jdormit/opencode-memsearch) — summarized but with raw transcript fallback

*   What it is: Same idea as Option 1 but uses Milvus Lite (a tiny vector database that is also just a file, usually `~/.memsearch/milvus.db`) and stores daily markdown notes at `.memsearch/memory/YYYY-MM-DD.md`.
*   Embeddings: Same ONNX `bge-m3` on CPU, or Milvus Lite's built-in.
*   Auto-index: Yes. Hook on `chat.message` extracts last turn → LLM summarizes to bullets → appends to markdown → re-indexes. Also cold-start injects recent notes.
*   What the agent gets: Three tools: `memory_search` (search notes), `memory_get` (expand a note), `memory_transcript` (read the raw original SQLite transcript centered on a turn). That last tool is the key difference — even though search is over summaries, the agent can still fetch granular raw data on demand.
*   Granularity: Hybrid — search is summarized, but detail is reachable in two steps.
*   Maintenance: Medium. Needs Python installed, first run downloads model, without a background daemon each search pays 5–10 seconds of Python startup; with daemon (~50ms) you keep a process running. One extra LLM call per turn (cost).
*   Good if you want human-readable daily notes plus the ability to drill to raw.

### Option 3: bojackduy/opencode-telescope — most granular, but built for you (the human), not the agent

*   What it is: A TUI plugin — the popup you open inside opencode's terminal UI with `<leader>f` or `/telescope`, like a fuzzy finder for your chat history.
*   Vector storage: Sidecar file that holds both a keyword index and, if enabled, a `sqlite-vec` vector table (`vec0`). Reads your `opencode.db` read-only, never modifies it. Updates incrementally in background while you type.
*   Embeddings: By default it does **not** use vectors at all — just fast keyword search. If you set `OPENCODE_TELESCOPE_ENABLE_VECTOR=1`, it expects `llama-server` running on `127.0.0.1:8081` with `nomic-embed-text-v1.5` to generate embeddings. That is the only option here that needs `llama-server` + VRAM.
*   Auto-index: Yes for the keyword sidecar — it syncs new conversation parts in small batches while you work. No prompting.
*   What the agent gets: Nothing directly — there is no agent tool, only the human picker. You search, you preview, you press Enter to jump to that session.
*   Granularity: **Fully raw and granular** — it indexes your actual prompts, assistant replies, patches, and can scope search like `patch:validateForSubmit` or `user:auth caching`.
*   Maintenance: Very low if you stay on keyword-only (no model, no server). Higher if you enable vector.
*   Good if you personally want to quickly find "that code snippet" yourself, but does not solve "agent needs to find it on its own after compaction."

### Option 4: chis.dev/session-search — most granular + hybrid, but not an opencode plugin

*   What it is: A standalone skill (a folder you drop into `~/.claude/skills` or similar) that indexes both Claude Code history (`~/.claude/projects/*.jsonl`) and opencode history in one place. Written as a research project, published Feb 2026.
*   Vector storage: Not a vector database at all — just `numpy` arrays (`session_embeddings.npy`) + SQLite `FTS5` for keywords + JSON, all under `~/.cache/session-search/`. Hybrid merge uses "Relative Score Fusion" (blends vector and keyword scores so thresholds like "0.65 = strong match" mean something).
*   Embeddings: `Qwen3-Embedding-0.6B` (600M parameters, 1024 numbers, 8K context) running either locally via `llama-cpp-python` with Metal (macOS) or remotely via any OpenAI-compatible `POST /v1/embeddings` endpoint you configure via `.env` + `EMBEDDINGS_URL`.
*   Auto-index: Semi-automatic — on each search it checks if `opencode.db` changed by looking at file modification time and each session's `time_updated`, then re-embeds only changed sessions.
*   What the agent gets: Not directly — it is a skill you invoke with `/session-search`, not a tool the agent can call as `session_search(query=...)`. You would need to wrap it.
*   Granularity: **Fully raw, two-level** — one fingerprint per entire session (all your questions concatenated) plus one fingerprint per individual turn. Searching finds which session and which exact turn.
*   Maintenance: Medium-high — Python venv, model download from Hugging Face, manual install as skill. Powerful and fast (1–4ms search for 10k vectors) but more steps than a one-line plugin.

### Other names you will see

*   `Stranmor/opencode-mem` — Rust + Postgres + pgvector. Needs a Postgres server you run separately. Powerful but high maintenance for your "no hassle" goal — not recommended here.
*   `opencode-semantic-memory` / `sqliteai/sqlite-vector` — MCP server + LanceDB variants. Same idea, different packaging, still need a separate server process.

## 6. How to choose for your stated preferences

Your clarified preferences:

*   Vector database is fine if it means more granular, detailed results.
*   Must index on its own, no prompting to store.
*   Prefer off-the-shelf, low hassle.
*   Want simple explanation, know `llama-server` but not much else.

Here is the decision in plain terms:

*   **If granular detail is the priority and you are okay with a vector file:**
    *   Want the agent to have a tool AND want zero prompting? Options 1 and 2 both auto-index. Option 1 is less detailed (summaries), Option 2 can reach raw detail via its transcript tool but costs an extra LLM call per turn and needs Python.
    *   Want the *most* granular raw text without summaries? Options 3 and 4 are more granular, but Option 3 has no agent tool and Option 4 is not an opencode plugin — both would need a tiny wrapper if the agent is to call them.

*   **If low hassle is the absolute priority:** Option 1 (`tickernelz/opencode-mem`) is the only one that is truly one line, no Python, no `llama-server`, no daemon, works on CPU, auto-indexes, auto-injects into compaction, and gives the agent a tool.

*   **There is no perfect single off-the-shelf that is simultaneously (a) one-line install, (b) agent tool, (c) fully raw granular, (d) auto-index, and (e) no `llama-server`/Python.** You pick the trade:
    *   `tickernelz` trades granularity for simplicity.
    *   `memsearch` keeps transcript granularity but adds Python + LLM cost.
    *   `telescope`/`session-search` keep full granularity but are built for the human, not the agent, unless wrapped.

## 7. Recommendation

Given you said vector database is okay and auto-index is required, and you prefer off-the-shelf:

**Start with Option 1: `tickernelz/opencode-mem` in its default local-CPU mode.**

Why this is the best first step, even though it is summarized:

1.  It is the only option where you try it for 5 minutes and know if it helps: add `"plugin": ["opencode-mem"]` to `~/.config/opencode/opencode.json`, restart, and it starts building memories in the background. No `llama-server`, no Python, no API key needed for search. Turn off `autoCaptureEnabled` and search still works — it will just search what it auto-captured via your existing provider.
2.  It is the only one designed as a compaction crutch: the same settings that control search also control what gets injected before compaction (`compaction.memoryLimit`) and at chat start (`chatMessage.maxMemories`). That directly addresses "short context and constant compaction" without you doing anything.
3.  It validates whether summarized detail is enough. For many teams, 2–6 bullets per turn is enough to recover decisions. If after a week you find yourself needing exact patches or error strings that summaries dropped, you will know the vector database was worth it but you need raw.

**If summaries prove too lossy, add Option 2 (`jdormit/opencode-memsearch`) as a second, not a replacement.** Its `memory_transcript` tool is the missing granular piece: search summaries, then fetch exact raw turns from the SQLite file when needed. Keep the vector file it creates (`~/.memsearch/milvus.db`) — you said that is fine.

**Keep Option 3 (`telescope`) keyword-only on the side for yourself even if you never enable its vector mode.** It costs almost nothing (just a TUI plugin line in `tui.json`), gives you instant raw grep for your own manual searches, and does not interfere with the agent's memory tool. Do not enable its `ENABLE_VECTOR=1` unless you want to keep `llama-server` running — you do not need it if you already have Option 1's ONNX model.

You do not need Option 4 unless you also want to unify Claude Code and opencode history in one index — if you only use opencode, it adds Python maintenance without extra benefit over the plugins.

## 8. What "keeping a vector database" actually means for you

In all these options the "vector database" is just a file or two next to your existing `opencode.db`:

*   `tickernelz`: `~/.opencode-mem/data` (Turso file + `.cache` for the model)
*   `memsearch`: `~/.memsearch/milvus.db` + `.memsearch/memory/YYYY-MM-DD.md`
*   `telescope`: sidecar next to its cache
*   `session-search`: `~/.cache/session-search/index/` with `*.npy` + `index.db`

Backup is copying the file. Deleting is removing the folder and restarting — it reindexes from the original `opencode.db`. No separate backup strategy, no cloud.

## 9. Concrete next steps to trial

1.  Install tickernelz:
    ```json
    // ~/.config/opencode/opencode.json
    { "plugin": ["opencode-mem"] }
    ```
    Restart opencode. A commented template appears at `~/.config/opencode/opencode-mem.jsonc`. Keep `embeddingModel` default (`Xenova/nomic-embed-text-v1`) — it is a good balance; switch to `Xenova/all-MiniLM-L6-v2` only if you want smallest/fastest. Leave `embeddingApiUrl` empty to stay local.

2.  Enable auto-capture without new keys (reuses your existing provider):
    ```json
    // in that same jsonc
    { "opencodeProvider": "anthropic", "opencodeModel": "inherit", "autoCaptureEnabled": true }
    ```
    If you use a different provider (openai, etc.), set that name instead. `inherit` means "use whatever model the current session is already using."

3.  Test: have a short session, wait ~30 seconds idle, then in a new session ask the agent: `memory({ mode: "search", query: "what did we do about the VCS crash?" })`. Check `http://127.0.0.1:4747` to see memories.

4.  After a week, decide: if summaries ever miss exact code, install `opencode-memsearch` alongside it for transcript-level search. If you as a human want raw keyword search, add `"@bojackduy/opencode-telescope"` to `tui.json` plugins and use `/telescope` with `patch:` scopes.

## 10. Open questions before building anything custom

You said off-the-shelf is preferred, so no custom build is proposed here. If off-the-shelf proves insufficient, the custom alternative that would meet all four of your criteria in one would be: a tiny opencode plugin that reads `opencode.db` raw, splits each message into turn chunks, fingerprints raw text with the same ONNX model on CPU, stores in `sqlite-vec` (`vec0`) + `FTS5`, merges with hybrid, and exposes `session_search` + `session_get` as agent tools — essentially a local-CPU, raw-granular version of session-search but as a native tool. That is ~1–2 weeks of work and is only worth pursuing if the trial above shows summaries are insufficient.

---
*Eval written 2026-08-28. Sources: in-repo session schema at `packages/core/src/session/sql.ts`, session service at `packages/opencode/src/session/session.ts`, tool registry at `packages/opencode/src/tool/registry.ts`, and public docs for tickernelz/opencode-mem, bojackduy/opencode-telescope, @zilliz/memsearch-opencode / jdormit/opencode-memsearch, chis.dev/session-search, Stranmor/opencode-mem, opencode-semantic-memory.*
