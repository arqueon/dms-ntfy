# DMS ntfy

A persistent [ntfy](https://ntfy.sh) review inbox for
[DankMaterialShell](https://danklinux.com).

The plugin is intentionally separate from the normal DMS notification center:
it does not create duplicate desktop notifications. A daemon polls the configured
topics and stores every message locally; a DankBar widget lets you review that
archive later.

![ntfy archive with All and per-topic views](assets/screenshot.png)

## Features

- Official ntfy icon and unread badge in both horizontal and vertical DankBars.
- One **All** view plus a section for every configured or previously seen topic.
- Persistent local history: messages survive DMS restarts and the ntfy server's
  temporary message cache. Nothing is removed until you explicitly dismiss it
  (unless you opt into a history limit).
- Read/unread state, per-topic unread counters, full-text local search, manual
  refresh, mark-all-read, and two-step dismissal.
- Shows ntfy title, body, topic, priority, tags, source instance, exact timestamp,
  click URL, attachment, and safe `view` actions.
- HTTP and broadcast actions are described but never executed.
- Works with ntfy.sh or any self-hosted instance, public topics, access tokens, or
  HTTP Basic authentication.
- Credentials are stored in the system keyring with `secret-tool`, never in
  `plugin_settings.json`.
- Composite architecture: one daemon owns polling and persistence while any
  number of horizontal/vertical widget instances share its live state.

## Requirements

- DankMaterialShell 1.5.0 or newer.
- `curl`, `secret-tool` (libsecret), and GNU `base64` on `PATH`.
- At least one ntfy topic with subscribe permission.

The client uses ntfy's documented JSON polling endpoint:
`/<topic1>,<topic2>/json?poll=1&since=<message-id>`. On first sync it imports all
messages still present in the server cache, then deduplicates them into the local
archive.

## Setup

1. Symlink or copy this directory to
   `~/.config/DankMaterialShell/plugins/ntfy`.
2. Scan plugins, enable **ntfy**, and add it to any DankBar:

   ```sh
   dms ipc plugin-scan scan
   ```

3. In Settings → Plugins → ntfy, set the instance URL and comma-separated topics.
4. Select the authentication method. Save an access token or password through the
   settings UI; alternatively:

   ```sh
   secret-tool store --label='DMS ntfy token' service dms-ntfy key token
   secret-tool store --label='DMS ntfy password' service dms-ntfy key password
   ```

Right-clicking the bar icon syncs immediately. Left-clicking opens the archive.

## IPC

```sh
dms ipc call ntfy status
dms ipc call ntfy refresh
dms ipc call ntfy markAllRead __all__
```

Mutation commands used by the UI (`markRead`, `markUnread`, `dismiss`,
`dismissRead`, and `clearHistory`) are also available over IPC. Dismissal is local:
it does not delete the original message from the ntfy server.

## Development

```sh
node tests/test-ntfy.js
jq . plugin.json
dms ipc plugin-scan rescan ntfy
dms ipc plugin-scan reload ntfy
```

Because QML caches imported JavaScript, restart DMS after changing `JS/ntfy.js`.

## Licensing

Plugin code is MIT licensed. `Images/ntfy-outline.svg` is the official ntfy outline
icon from `binwiederhier/ntfy`, used unmodified under Apache-2.0; see `NOTICE` and
`LICENSES/Apache-2.0.txt`.
