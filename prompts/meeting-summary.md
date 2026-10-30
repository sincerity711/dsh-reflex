Write meeting minutes in English based on the caption records in the data section below. Use English for every generated heading, explanation, decision and action item, even if some source material is in another language. Preserve people's names, product names and identifiers as recorded.

Source material:
- The records come from Microsoft Teams live captions. Speech recognition may introduce spelling, segmentation or homophone errors.
- Markers such as `[Gap ...]` indicate missing content; older captures may use localized gap labels. Do not invent what was said during a gap.
- Read the complete caption files referenced in `files`, unless their complete contents are already included in the data section.

Output Markdown minutes with these sections:

## Summary
Describe the meeting's purpose and conclusions in 3–6 sentences.

## Decisions
- One decision per bullet, with its source timestamp when available, for example (10:32).

## Action Items
| Action | Owner | Due Date | Source Timestamp |
|---|---|---|---|
Use "Not specified" for an owner or date not explicitly stated in the source.

## Open Questions
- Include unresolved discussions, unclear captions and possible omissions caused by capture gaps.

Use only the source evidence. Do not invent facts; label missing information "Not specified".

When recent same-title meetings are provided, use their timing, topics and context to determine whether they are continuous segments of the same meeting. Where supported, combine the full source material into updated minutes. A matching title alone is insufficient. Otherwise summarize the current meeting separately and explain the uncertainty. If `archiveTranscriptPath` is provided, read it for earlier segments already archived together.

When plugin archiving is enabled, follow the additional merge-selection output instructions. The program saves `transcript.md` and the raw logs; do not generate, translate or rewrite the transcript.
