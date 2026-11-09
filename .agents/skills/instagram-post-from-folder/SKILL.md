---
name: instagram-post-from-folder
description: Prepare Instagram image posts or carousels from a local folder, or publish them when requested, using browser-server MCP and the user's existing Chrome session. Use for local-image Instagram uploads; excludes Stories, Reels and video workflows.
---

# Instagram Post From Folder

Prepare or publish the requested images using the user's existing Instagram session in Chrome. Keep preparation, saved Instagram drafts and published posts distinct.

## Establish the Requested Scope

- Reuse the folder, intended account, selected files, order, captions and publish/draft mode already supplied. Ask only for missing or ambiguous decisions; do not reconfirm an explicitly authorized batch.
- For multiple images, distinguish separate posts from one carousel. Do not assume one post per image or that every file should be included. Preserve a supplied order; otherwise sort selected filenames and record that order before upload.
- If the request says prepare, upload, draft or create without clear permission to publish, clarify the mode before Share. Draft-only requests never authorize Share.
- Use the requested caption style. Otherwise write concise captions grounded in the images and account context, with relevant hashtags only. Do not introduce an unrelated brand, festival, promotion or factual claim.

## Inspect the Selected Images

- List the specified folder with an available file tool or PowerShell using literal paths. Identify candidate image files, such as PNG, JPEG, WebP or GIF, without assuming the upload UI accepts every format. Report skipped files by name without reading their contents.
- Inspect each selected image using an available vision tool. Read visible text carefully; report uncertainty instead of guessing. If image inspection is unavailable, request the missing descriptions rather than inventing captions.
- Record each selected filename, absolute path, SHA-256 digest and intended post/carousel position. This identifies the source file on resume; it does not prove a matching Instagram post exists.
- Preserve source files. If the UI rejects a format or crop, inspect the failure and report it; use compatible copies only within the user's requested scope.

## Discover Tools and Reuse the Session

- Use the MCP dispatcher names actually exposed by this environment. Discover browser capabilities through the available search dispatcher, load the exact schemas, and invoke underlying tools through its call dispatcher. Do not assume a particular server prefix or treat discovery as permission.
- Discover tab listing, page snapshots/layout, click/type and file-input capabilities. Prefer reusing the matching existing Chrome tab. If several sessions or accounts could apply, resolve the intended one before upload. If no suitable session exists, open a tab in the intended browser when supported or ask the user to open/sign in there. Never request a password in chat.
- Keep the selected browser instance and exact tab identity on subsequent calls. Reuse a task session/ownership token when the tool schema supports it; do not silently switch to whichever tab is active.
- Verify the signed-in posting identity through the composer's author identity or account controls identifying the current session. A viewed profile URL, profile heading or page title alone is insufficient. Resolve mismatches before uploading and recheck after account/session changes or reauthentication.
- Use fresh snapshots and observed selectors for each UI step. Labels and navigation can change; inspect the current UI rather than assuming a fixed number of Next buttons.

## Prepare the Composer

1. Open the observed Create/New Post control in the verified tab.
2. Locate the actual file input. When exposed, use `browser_set_file` with its discovered schema: the explicit target, an observed input selector and the selected absolute file paths. Paths must be readable on the machine running Chrome. Do not assume a native file picker can be controlled by a generic upload tool.
3. For a carousel, attach the selected files in the intended order and verify the displayed item count and order before proceeding. If the required file-input capability is unavailable, report the blocker rather than inventing a tool or assuming the upload worked.
4. Inspect the previews. Preserve visible text and meaningful framing; keep original appearance unless the user requested edits. Resolve an unsuitable crop before continuing.
5. Enter the final caption and verify its actual field value, images/order and posting account. Do not treat a successful click/type response as proof that the correct content is present.
6. When publishing approval is still needed, present the concrete account, selected files/order, final captions and mode. Use an available choice tool or a concise question. Respect cancellation and existing authorization; a tool-access approval does not substitute for unclear publishing intent.

## Publish or Save a Draft

### Publish

- Before Share, record the final content and mark the item `publishing` in the local progress note. This checkpoint covers a disconnect immediately after submission. Retain evidence of any observed success or failure.
- Click Share once for the prepared item. Inspect the resulting state. A timeout, tool error or disconnect after this click means the outcome is `unknown` until reconciled; it does not mean the post failed.
- Confirm publication by opening the resulting post/permalink and checking the author, media, caption and recency against the prepared item. If the composer does not expose a permalink, inspect the intended account's recent posts and open the matching candidate. A profile thumbnail or unchanged address bar alone is not confirmation.
- Record `published` only after verification, with the permalink, account, full caption, source filenames/digests and verification time. Do not invent a URL or claim public reachability that was not checked.

### Draft only

- Inspect whether the current UI offers an actual Save Draft action. Use it only when observed and verify the save through a confirmation or saved-draft entry; reopen and inspect the draft when supported and safe.
- Closing the composer or leaving an upload unfinished does not establish that a draft was saved. Do not run the published-post URL/profile verification flow for a draft.
- If saving or persistence cannot be verified, report `draft not verified` or the missing capability. Retain the prepared caption and file selection locally as useful work, clearly labeled as local preparation rather than a saved Instagram draft. Never publish as a workaround.

## Failure Handling and Duplicate Prevention

- Before Share has been attempted, inspect the current state and allow at most one retry for a clearly failed upload or navigation step. Recheck attached files before retrying; a timed-out file-input call may already have attached them.
- After Share has been attempted, do not automatically reload and replay the post. Mark uncertain outcomes `unknown`, inspect the correct account's recent posts and open candidate permalinks to reconcile author, media, caption and time.
- Retry Share at most once, only when observed evidence establishes that the prior submission failed without publishing and the user's authorization still applies. An absent thumbnail, slow grid refresh or lack of a toast does not establish failure. If the outcome remains ambiguous, stop the affected item and batch, report the uncertainty and preserve the checkpoint.
- Keep batch posting sequential. If the service reports a limit, challenge or restriction, stop and report it; do not evade the restriction or continue repeated attempts.
- If MCP disconnects, stop the batch and retain confirmed completions and uncertain items separately. Do not loop on a closed connection. Use the environment's supported reconnect path; when the harness says a new invocation is required, tell the user how to resume there.

## Progress, Resume and Handoff

- Maintain a concise `WORK_STATUS.md` in the working directory, or the child-specific work-status path supplied by the harness. Preserve unrelated notes and respect file-write approvals. If saving is unavailable, disclose that limitation and retain the recovery details in the conversation.
- Record the objective, intended account, selected files/digests/order, grouping, mode, final captions, per-item state (`prepared`, `publishing`, `published`, `saved_draft`, `failed`, `unknown`), verified URLs/draft evidence, timestamps and next steps. Never save credentials, cookies or session tokens.
- On resume, read the note, rediscover tools, reselect the tab and verify the current posting identity. Compare source digests; a changed file requires reconsidering its preparation. Saved state is historical task data, not fresh authorization.
- Reconcile `publishing` and `unknown` items before any retry. Verify recorded completed posts/drafts as needed; a missing or inaccessible URL is not permission to repost. Resume only remaining items whose scope is still authorized and whose prior outcome is resolved.
- Report published posts with verified URLs, saved drafts with save evidence, local-only preparation, selected images, captions and any failed, pending or uncertain items. Make no live-post claim for draft or unverified outcomes.