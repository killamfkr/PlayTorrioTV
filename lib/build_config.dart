/// Set via `--dart-define=LOW_RAM=true` (lowram Gradle flavor).
const bool kLowRamStartup = bool.fromEnvironment('LOW_RAM', defaultValue: false);
