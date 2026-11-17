# Statistics semantics

Every real `AgentMonitor.refresh()` records one timestamped measurement, including partial/unavailable sources. Overall and per-source latency use a monotonic clock; local calendar grouping uses Europe/Oslo. Display and persistence failures are separate states.

SQLite retains raw refresh/provider counts and timings, compact last state, duration rollups, exact boundary intervals, and attention transitions. It does not retain prompts, transcripts, task titles, tool inputs/results, navigation commands or credentials. Session keys and attention reasons support local continuity. Multiple writers serialize a transaction and reload the global last frame, preventing overlapping time from being counted twice.

Durations require adjacent observations no more than15seconds apart. Known sessions contribute only when their own observations and source are usable. An unrelated missing/stale session makes overall coverage incomplete but does not erase another session's confirmed work or waiting. Sleep and collection outages add no agent-time.

Working and waiting durations are agent-seconds: two working agents observed for five seconds contribute ten working agent-seconds. Average concurrency divides agent-time by observed wall time; it does not divide by the whole selected month as if unobserved days were idle. Coverage is reported separately against the requested range. Child agents are excluded from duration summaries in the initial app.

Hour/weekday buckets split by local calendar, including repeated DST hours. Interior minute rollups keep monthly queries bounded; exact clipped intervals handle selected-range edge minutes. Charts cap their point count and separate fully unobserved buckets; partially observed buckets average only available time.

An attention episode begins with a confirmed needs-you observation. A wait already underway at first observation has an unknown beginning; a wait interrupted by source loss has an unknown ending. These censored episodes are distinguishable from a fully observed resolved wait. Mean/p95 resolved waits exclude censored durations and are estimates at collection resolution, not exact human-response timers. A completed attention episode is not a completed coding task.

The early development collector incorrectly let an unrelated stale session invalidate an entire source, fragmenting a continuous wait. Format3 uses new derived tables and a separate continuity baseline. Older derived estimates remain in the database for inspection and are excluded from current duration/episode reports; original raw refresh/latency measurements remain available. Reports disclose this boundary. No history is deleted to hide that issue.

No token/cost, productivity, completed-work, or human-effort conclusions are inferred from these observations.
