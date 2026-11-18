import Foundation

/// Helper run detached by the app after it quits: swaps the app bundle, restoring the old one if the move fails,
/// clears the quarantine flag and reopens the app. Arguments are positional (never interpolated into the text):
/// `bash swap.sh <pid> <target.app> <new.app>`. `MS_OPEN` overrides the final `open` command (tests).
public enum SwapScript {
    public static let text = """
    #!/bin/bash
    PID="$1"; TARGET="$2"; NEW="$3"
    for _ in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    BACKUP="${TARGET}.previous"
    rm -rf "$BACKUP"
    if mv "$TARGET" "$BACKUP"; then
      if mv "$NEW" "$TARGET"; then
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        rm -rf "$BACKUP"
      else
        rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"
      fi
    fi
    "${MS_OPEN:-open}" "$TARGET"
    rm -rf "$(dirname "$(dirname "$NEW")")"
    """
}
