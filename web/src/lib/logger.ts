type Level = "debug" | "info" | "warn" | "error";

/**
 * Server-side JSON logger, one object per line on stdout, in the same
 * shape as catalogue-api's slog output (time, level, msg, then fields).
 */
function log(level: Level, msg: string, fields: Record<string, unknown> = {}) {
  console.log(
    JSON.stringify({ time: new Date().toISOString(), level: level.toUpperCase(), msg, ...fields }),
  );
}

export const logger = {
  debug: (msg: string, fields?: Record<string, unknown>) => log("debug", msg, fields),
  info: (msg: string, fields?: Record<string, unknown>) => log("info", msg, fields),
  warn: (msg: string, fields?: Record<string, unknown>) => log("warn", msg, fields),
  error: (msg: string, fields?: Record<string, unknown>) => log("error", msg, fields),
};
