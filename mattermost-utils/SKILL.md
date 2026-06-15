---
name: mattermost-utils
description: >-
  Answer questions about a Mattermost conversation by exporting it with the
  mmutils CLI and reading the transcript. Use this whenever the user pastes a
  Mattermost permalink or post ID, or asks you to summarize, search within,
  find something in, or answer a question about a specific Mattermost thread,
  message, or discussion — even if they don't mention mmutils by name. Ground
  the answer in the exported transcript rather than guessing. If the user
  describes a conversation but has no permalink, use `mmutils search` to find
  the relevant message first, then export and answer.
---

# Answering Mattermost questions with mmutils

`mmutils` searches Mattermost for messages and exports a thread the
authenticated user can see into local files. Use the Markdown transcript as the
source of truth and answer from it — never from memory of the conversation,
which you don't have.

**Default server:** when the user hasn't specified one (a bare post ID, or a
`search`), pass `--server https://chat.duckduckgo.com/`. A full permalink
already carries its server, so don't add `--server` in that case.

## Workflow

1. **Find the thread.** You need a permalink
   (`https://<server>/<team>/pl/<post-id>`) or a post ID. If the user only
   describes the conversation, search for it first — don't guess:
   ```bash
   mmutils search "<keywords>" --server https://chat.duckduckgo.com/
   ```
   It prints matching messages with permalinks (newest first); pick the relevant
   one.

2. **Check the token.** mmutils reads `MM_TOKEN` from the environment and never
   prints it. If it's unset, ask the user to `export MM_TOKEN=<token>` (from
   Mattermost: Profile → Security → Personal Access Tokens; or the `MMAUTHTOKEN`
   browser cookie if that's disabled).

3. **Export to Markdown.**
   ```bash
   mmutils save "<permalink-or-post-id>" --format markdown
   ```
   If `mmutils` isn't installed, run it without installing:
   ```bash
   go run github.com/selman92/mmutils/cmd/mmutils@latest save "<permalink>" --format markdown
   ```
   Add `--with-files` only when the question is about attachments.

4. **Read the transcript.** The command prints `Saved N post(s) to <dir>`. Read
   `<dir>/thread.md` — it has each message with author and timestamp.

5. **Answer from the transcript.** Quote authors/timestamps where it helps, and
   if the thread doesn't contain the answer, say so plainly rather than
   inventing one. mmutils only exports what the token's user is allowed to see,
   so an incomplete export means an incomplete answer — call that out.

## Errors

- `no access token found` → `MM_TOKEN` isn't set (step 2).
- `403` / access denied → the token's user can't read that thread (private
  channel/DM they're not in). Nothing to export; tell the user.
- `404` / not found → wrong permalink/ID, or not visible to the user.
- `no Mattermost server configured` → bare post ID with no `--server`/profile.
