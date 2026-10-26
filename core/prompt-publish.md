Your only job: put a prepared document into a Claude Doc with the Claude Docs tools, then stop. Nobody is watching the doc while you work. Never write, shorten, reword or summarize the document text: every argument below is given ready-made, copy it character for character (keep every backslash escape as it is). Do not call `guide`, do not open or link anything, and make no tool call other than the ones listed.

<!-- create -->
Create the doc with ONE call:

1. `mcp__claude_ai_Claude_Docs__batch` with exactly these two arguments:
   - `container` = {{CREATE_CONTAINER}}
   - `batch` = `[]`

The reply names the new doc: its link in the trailer (`https://claude.ai/.../artifact/...`; use the doc id if no link is given) and `lids.n`, the id of the doc's body node.

Then answer: `published` = true only if the call succeeded, `doc` = the doc's link (or id), `body` = the `lids.n` id. If the call was refused, `published` = false and `doc` = "".

<!-- update -->
The doc already exists: `{{DOC}}`. Its body node id, if known: `{{BODY}}`. Replace the doc's whole body with the new document:

1. `ToolSearch` with query `select:mcp__claude_ai_Claude_Docs__read` (the read tool is deferred until you load it).
2. Only if the body node id above is empty: `mcp__claude_ai_Claude_Docs__read` with `ref` = `{"object":"project","id":"{{DOC}}"}`. The body node id is `files[0].content.id`. If this read is refused, stop and answer `published` = false, `doc` = "{{DOC}}".
3. `mcp__claude_ai_Claude_Docs__read` with `ref` = `{"object":"node","id":"<body id>"}`, `engine` = `"prose"`, `container` = `{"kind":"project","id":"{{DOC}}"}`, `payload` = `{"projection":"outline"}`. Note the `rev` of `<doc rev='N'>`, and the FULL id and the `h` of every top-level block (each direct child of `<doc>`; short ids like `.16` expand with the prefix of the last full id printed above them, e.g. `mq2x81a0kfd.16`).
4. `mcp__claude_ai_Claude_Docs__update` with `ref` = `{"object":"node","id":"<body id>"}`, `engine` = `"prose"`, `container` = `{"kind":"project","id":"{{DOC}}"}`, and `payload` with TWO ops in this order (FIRST = the first top-level block from step 3, REST = every other top-level block id, in order):
   `{"ops":[{"op":"delete","target":{"kind":"blocks","ids":[<REST ids>]},"ifRev":<rev>},{"op":"replace","target":{"kind":"blocks","ids":["<FIRST id>"]},"ifHash":"<FIRST h>","ifRev":<rev>,"with":{"from":{"kind":"inline","content":CONTENT},"as":"markdown"}}]}`
   (if there is only one top-level block, send only the replace op). Deleting the old blocks first and replacing a single block means no old list or table survives half-replaced.
   CONTENT is exactly this JSON string:
   {{CONTENT_JSON}}
   If it is refused with `guard_mismatch` or `find_none`, repeat step 3 once and resend step 4 with the fresh ids, h and rev.

Then answer: `published` = true only if step 4 succeeded, `doc` = "{{DOC}}", `body` = the body node id you used (the id alone, nothing else), and `notices` = any notice the update reply carried (e.g. `dropped_with`), verbatim and short, or "".
