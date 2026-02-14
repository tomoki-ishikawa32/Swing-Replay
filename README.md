# Swing Replay

Golf swing capture and relay project.

MVP architecture:
- iPhone app: capture + encode + send
- iPad app: receive + buffer + decode + display
- Shared module: packet/chunk/buffer/network logic (`SwingReplayCore`)

## Current Repository Status

This repository contains iPhone/iPad app targets and a shared Swift package for core pipeline components.

- `Package.swift`: Swift Package definition
- `Sources/SwingReplayCore`: sender/receiver shared logic
- `Tests/SwingReplayCoreTests`: package unit tests
- `SwingReplayApps.xcodeproj`: app project (`SwingReplayPhone`, `SwingReplayPad`)
- `Apps/SwingReplayPhone`: iPhone app entry/UI/runtime
- `Apps/SwingReplayPad`: iPad app entry/UI/runtime
- `Config/*.plist`: app permissions and launch/orientation settings
- `TASK_LIST.txt`: implementation checklist (source of truth)

## Implemented (Task List aligned)

Implemented in code:
- A0-1/A0-2: iPhone app target + Info.plist permissions (camera/local network/bonjour)
- A0-3: logging base with `OSLog`
- A1-1..A1-5: phone-side Multipeer advertise/session/reconnect flow
- A2-1..A2-5: camera session setup (back camera, target 960x540, 24fps, sampleBuffer callback, frame interval logging)
- A3-1..A3-5: realtime H.264 encoder (`VTCompressionSession`) and per-frame output
- A4-1..A4-5: packet header/chunking/send API/rate control + sender metrics
- B1-1..B1-5: pad-side Multipeer browse/session/reconnect flow
- B0-1..B0-4: iPad app target + responsive fullscreen UI + status/debug labels
- B2-1..B2-5: chunk receive/parse/reassemble with overload protection
- B3-1..B3-4: delay buffer + playback gate + reset behavior + centralized delay setting
- B4-1..B4-5: VideoToolbox H.264 decode path (SPS/PPS update, decode session, corrupted frame drop, in-flight throttle)
- B5-1..B5-4: AVSampleBufferDisplayLayer based renderer + SwiftUI wrapper + fill/fit policy + latest-frame priority
- B6-1..B6-4: fail-safe controller (timeout restart, buffer overflow reset, safe state transitions)

## Core Files

- `Sources/SwingReplayCore/PhoneSenderSession.swift`
- `Sources/SwingReplayCore/PadReceiverSession.swift`
- `Sources/SwingReplayCore/CameraCaptureService.swift`
- `Sources/SwingReplayCore/RealtimeH264Encoder.swift`
- `Sources/SwingReplayCore/SenderTransportPipeline.swift`
- `Sources/SwingReplayCore/FramePacket.swift`
- `Sources/SwingReplayCore/FrameChunker.swift`
- `Sources/SwingReplayCore/DelayBuffer.swift`
- `Sources/SwingReplayCore/ReceiverPipeline.swift`
- `Sources/SwingReplayCore/RealtimeH264Decoder.swift`
- `Sources/SwingReplayCore/ReceiverVideoView.swift`
- `Sources/SwingReplayCore/ReceiverFailSafeController.swift`

## Verify

```bash
swift test
xcodebuild -project SwingReplayApps.xcodeproj -scheme SwingReplayPhone -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project SwingReplayApps.xcodeproj -scheme SwingReplayPad -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Next Work (still pending in TASK_LIST)

- A5: sender side real-device long-run and reconnect validation
- C: end-to-end UX/stability validation with iPhone + iPad pair
