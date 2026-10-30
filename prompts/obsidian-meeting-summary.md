Prepare English minutes for this Teams meeting in the configured Obsidian vault working directory. Read its AGENTS.md and the relevant entry points and meeting archive conventions it requires. Read only the material needed for this task; do not reorganize the vault.

Write all generated minutes, headings, explanations, decisions and action items in English, regardless of the source language. Preserve people's names, product names and identifiers as recorded. The original transcript must remain in its captured language and must not be translated or rewritten.

Read the complete current caption records and capture gaps in `files`, together with the historical material in `previousMeetings`. Teams speech recognition may introduce spelling errors, incorrect sentence boundaries and missing content. Do not invent missing information.

Try to combine same-title meetings that ended within the configured lookback window when timing, topics, speakers and context support treating them as continuous segments of the same meeting. Reconnection, a briefly missing window or an immediately resumed discussion may indicate continuity. A matching title alone is insufficient; do not combine separate recurring meetings from other dates. If uncertain, summarize only the current meeting and explain why in Open Questions.

`previousMeetings.record` may be a truncated preview. Read the complete `recordPath` for any segment you intend to combine. If `archiveTranscriptPath` is provided, read that complete archived transcript too: it may include earlier continuous segments. Do not reconstruct source evidence from a previous summary alone. Avoid repeating duplicated capture content in the minutes, while preserving distinct contributions. Cite available source timestamps and segment runIds. Use "Not specified" for people, owners or dates without explicit supporting evidence.

Output only the merge-selection marker followed by Markdown minutes. The first line must be:
<!-- reflex-merge: [] -->
When combining segments, replace the empty array with the runId strings of the supplied candidates actually included in the minutes. Do not include any other runIds. Then use these sections:

## Summary
Describe the meeting's purpose, important progress and conclusions in 3–6 sentences.

## Decisions
Include available source timestamps for each decision.

## Action Items
| Action | Owner | Due Date | Source Timestamp |
|---|---|---|---|

## Open Questions
Include unresolved issues, unclear captions and possible omissions caused by capture gaps.

The plugin performs all file archiving in code. Following the existing Obsidian convention, it saves a meeting entry note and matching `ai-summary.md` and `transcript.md` under `02_Sources/Meetings`, retaining each original capture segment and raw log. The program copies or concatenates complete source records to produce `transcript.md`. Your responsibility is the minutes only: do not generate or rewrite transcripts, create or modify files, or commit Git changes.
