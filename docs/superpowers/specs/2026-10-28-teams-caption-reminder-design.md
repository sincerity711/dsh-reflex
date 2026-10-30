# Teams caption visibility reminder

Approved by the user on 2026-10-28: notify after five seconds of an unreadable caption panel or a frozen meeting window. Keep notifications in English.

Reuse teams.captions.unavailable and the existing local notification action. The resident watcher detects minimized, covered, off-screen or stalled meeting windows; the capture task detects a missing caption panel. Both use a five-second threshold and include an actionable hint to keep the meeting or live captions window visible. A visible empty panel is silence, not a fault. Notify once per episode, rearm after recovery, and group simultaneous signals for one meeting. A working popped-out caption window suppresses meeting-window freeze alerts.

Keep raw transcript preservation and meeting identity intact. No model is involved in reminders. Update and validate the local rules and install the new Teams executable. Use virtual-time replay to check the threshold, recovery, deduplication and silence behavior; do not run a real meeting or prompt test.
