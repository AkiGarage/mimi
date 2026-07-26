# Mimi Local Protocol

## HTTP

- `GET /health`: local server liveness and mode.
- `GET /status`: current status, billing snapshot, recent diagnostic events, and local diagnostic file paths.

## WebSocket

- Endpoint: `ws://127.0.0.1:8787/ws`
- Chrome extension mode: `real`
- No `auto` or `mock` session mode is supported in the product path.

## Client Messages

```json
{"type":"start","mode":"real","targetLanguageCode":"ja"}
```

```json
{"type":"stop"}
```

```json
{"type":"audio_stream_end"}
```

This is for explicit diagnostics or shutdown-style control only. The Chrome extension must not send it automatically during normal real-time translation.

Future audio input messages can be binary PCM chunks:

- 16 kHz
- signed 16-bit little-endian
- mono
- about 100 ms per chunk

## Server Messages

```json
{"type":"status","status":"translating"}
```

```json
{"type":"audio_format","sampleRate":24000,"channels":1,"encoding":"pcm_s16le"}
```

Binary output frames are raw translated audio PCM in the announced format.

Additional text messages:

```json
{
  "type": "billing",
  "billing": {
    "period": "month",
    "month": "2026-06",
    "usedSeconds": 12,
    "remainingSeconds": 1788,
    "usage": {"inputTokens": 250, "outputTokens": 500, "totalTokens": 750, "unknownTokens": 0},
    "estimatedUsage": {"inputTokens": 300, "outputTokens": 550, "totalTokens": 850, "unknownTokens": 0},
    "displayUsage": {"inputTokens": 300, "outputTokens": 550, "totalTokens": 850, "unknownTokens": 0},
    "cost": {"totalUsd": 0.0126, "totalJpy": 2.016, "usdJpyRate": 160}
  }
}
```

```json
{"type":"transcript","kind":"output","text":"...","languageCode":"ja"}
```

## Safety

The server must stop if API key, quota, origin, or billing state is invalid.
