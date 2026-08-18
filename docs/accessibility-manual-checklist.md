# Accessibility Manual Checklist

These steps are for a later human VoiceOver pass. They are not automated and are not marked passed by this issue.

- Open the status item with VoiceOver or keyboard and confirm the panel's first focus is the Agent filter.
- Tab through Agent, Model, Performance range, View Trends, and Settings. Confirm a visible focus ring that is not color-only.
- Open Trends, move into each exact-value table, and confirm the spoken cell includes time bucket, series or burn part, raw identity, absolute value, and quality/state/coverage.
- Confirm Output series remain distinguishable by dash, glyph, and text; Burn parts remain distinguishable by symbol, texture name, and text.
- Open Settings and reach Launch at Login, Enhanced telemetry, Preview/Copy/Save/Prepare Diagnostics, Reset, and Check for Updates.
- Press Escape from Trends, Settings, a diagnostics confirmation, and Reset confirmation. Focus must return to the control that opened that layer. A later Escape from summary must dismiss the panel and restore the status item.
- Enable Reduce Motion and confirm charts still refresh values without continuous translation. Do not change system settings from automation.
- Cancel and repeat Escape. Confirm no extra Reset, Copy, Save, or Prepare side effects.

This issue does not claim final system VoiceOver certification.
