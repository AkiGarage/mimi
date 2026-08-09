# MimiForMac M1 capture spike

This is an independent Swift Package for the native Mac capture spike. It is
macOS 14.2+ and has no third-party dependencies.

The public seams are intentionally small:

- `AudioSourceProviding` and `AudioSource` for explicit source enumeration/selection.
- `CaptureBackend` and `CaptureSession` for lifecycle and backend substitution.
- `ScreenCaptureKitBackend` for a real app-filtered audio stream with
  `excludesCurrentProcessAudio`.
- `CoreAudioProcessTapBackend` for real `CATapDescription` construction,
  process-object PID resolution, a private aggregate device, IOProc sample
  delivery, and reverse-order teardown.
- `StreamingPCMConverter` for stateful Float32/multichannel to 16 kHz signed
  Int16 mono packets (1,600 samples per ~100 ms chunk).
- `CaptureMetricsCollector` for count, level, and rolling checksum only.

Both adapters have real sample-delivery paths and emit no synthetic audio.
Process Tap uses a private, non-persistent aggregate device and excludes the
Mimi process (plus configured helpers) from system capture. ScreenCaptureKit
uses app-level filtering and `excludesCurrentProcessAudio`. Permission prompts,
three-source audio evidence, and loop exclusion are still `UNVERIFIED` until a
human-assisted run on real hardware.

No API key, transcript, URL, window title, raw PCM, or audio file is read or
stored by this package.
