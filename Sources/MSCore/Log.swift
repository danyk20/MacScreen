import os

public enum Log {
    /// Returns a logger for the given category under the app subsystem.
    public static func logger(_ category: String) -> os.Logger {
        os.Logger(subsystem: MSConstants.logSubsystem, category: category)
    }
}
