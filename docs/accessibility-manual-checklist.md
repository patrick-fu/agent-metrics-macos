# Accessibility Manual Checklist

These steps are for a later human VoiceOver pass. They are not automated and are not marked passed by this issue.

- Open the status item with VoiceOver or keyboard and confirm the panel's first focus is the Agent filter.
- Tab through aggregate window, Settings, Agent, Model, the conditional Performance action, Data Quality, and View Trends. Confirm the sequence wraps in both directions and has a visible focus ring that is not color-only.
- Open Trends. Confirm the Back control stays pinned while the metric content scrolls on a short display. Move into each exact-value table and confirm the spoken cell includes time bucket, series or burn part, raw identity, absolute value, and quality/state/coverage.
- Confirm Output series remain distinguishable by dash, glyph, and text; Burn parts remain distinguishable by symbol, texture name, and text.
- Open Settings and reach Launch at Login, Aggregate window, Menu bar cadence, Enhanced telemetry, Check for Updates, Data & Diagnostics, and About & Updates.
- Open Data & Diagnostics. With no preview present, confirm Tab moves directly from Preview Diagnostics to Copy Diagnostics. After creating a preview or prepared public-issue text, confirm the newly visible selectable text enters the Tab sequence and disappears from it when its content is cleared.
- Confirm Copy, Save, and Prepare Public Issue each show their own one-time confirmation. Confirm the native save panel accepts Tab and Escape, and that no file is claimed after cancellation.
- Review Reset Data scope, continue to the separate destructive confirmation, then cancel. Do not confirm Reset during release acceptance against a user's real store.
- Open About & Updates and confirm the app version, minimum macOS version, update-feed boundary, metric definitions, privacy boundary, and Check for Updates are spoken without duplicated fragments.
- Press Escape from Trends, Settings, Data & Diagnostics, About & Updates, a diagnostics confirmation, and Reset confirmation. Focus must return to the control that opened that layer. A later Escape from summary must dismiss the panel and restore the status item.
- Enable Reduce Motion and confirm charts still refresh values without continuous translation. Do not change system settings from automation.
- Cancel and repeat Escape. Confirm no extra Reset, Copy, Save, or Prepare side effects.

This issue does not claim final system VoiceOver certification.
