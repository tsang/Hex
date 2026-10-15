---
"hex-app": minor
---

Auto text-insertion engine: when the Apple Screen Sharing client is in the foreground, transcripts are typed as plain hardware-like keystrokes so they traverse the remote input relay intact (Unicode payloads and Accessibility inserts degrade there); native insertion is used everywhere else. Clipboard paste is also bypassed while mirroring since relay clipboard sync can lag.
