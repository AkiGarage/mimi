# M1 backend decision record

## Current spike decision

Keep both adapters behind `CaptureBackend` for the Phase 0 comparison. Both now
have real sample-delivery paths: Process Tap drains a private aggregate device
through an IOProc, while ScreenCaptureKit provides an app-filtered SCStream with
`excludesCurrentProcessAudio`.

Core Audio Process Tap remains the preferred V1 candidate because it supports a
global tap with explicit process-object exclusion as well as a selected-process
tap. This is an implementation decision only: actual permission behavior,
three-source capture, source restarts, and self-audio exclusion remain
`UNVERIFIED` until measured on real hardware.

## Decision gate

After three source-app runs of five minutes each, fill in
`SPIKE-LOG-TEMPLATE.md` with only numeric/non-content evidence. Revisit the
decision by comparing latency, CPU, source coverage, permission UX, and
stop/source-ended behavior under the same build. Do not mark either backend
selected solely from unit tests or successful object creation.
