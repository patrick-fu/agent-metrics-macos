# UI / accessibility evidence

THROW AWAY. Synthetic fixtures only.

Automated browser checks were run against `bounded-runtime.throwaway.html` served locally. These checks cover keyboard, accessible names, non-color text, reduced motion, and the expandable data table. They do **not** certify macOS VoiceOver speech, rotor behavior, or status-item live-region chatter.

| Check | Result |
| --- | --- |
| Page language and title | PASS |
| Popover visible on load | PASS |
| Filter and drill controls have names | PASS |
| Live KPI drill has an accessible name | PASS |
| Keyboard focus lands on a control | PASS |
| Drill-down heading | PASS |
| Expandable data table with caption and headers | PASS |
| Table uses text coverage marks, not color only | PASS |
| Escape returns to the summary | PASS |
| Reduced-motion toggle removes the pulse class | PASS |
| Hidden popover stops detail snapshot builds | PASS |
| Hidden popover still updates the status-item light snapshot | PASS |
| Status item uses non-color quality/state marks | PASS |
| Status item is a polite live region | PASS |

## Manual acceptance still required

- System VoiceOver reading of the 3-minute summary, drill-down buttons, and live status-item updates
- VoiceOver rotor / table navigation in the real AppKit/SwiftUI popover
- Whether polite live updates of the status item are too chatty at 1 Hz
