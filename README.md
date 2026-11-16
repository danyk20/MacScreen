# MacScreen

MacScreen turns a second Mac into an external display for another Mac: the Host
creates a virtual display and streams it over the network to the Display Mac.

**Status:** early development.

## Requirements

- Display Mac: macOS 12.0+
- Host Mac: macOS 12.3+

## Build

```
swift build
swift test
```

## Notes

MacScreen uses the private `CGVirtualDisplay` API and is not notarized.

See [PLAN.md](PLAN.md) for the full design and task plan.
