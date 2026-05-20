export interface ParsedSummary {
  overallSummary: string;
  finalSummaryString: string;
  topic: string;
  startTime: string;
}

export interface ParsedCue {
  startTime: number;
  endTime: number;
  duration: number;
  speaker: string;
  text: string;
}

type SummaryInput = Partial<Record<keyof ParsedSummary, unknown>>;

const TIMESTAMP_SEPARATOR = "-->";

export function parseSummary(summary: SummaryInput): ParsedSummary {
  return {
    overallSummary: readString(summary.overallSummary),
    finalSummaryString: readString(summary.finalSummaryString),
    topic: readString(summary.topic),
    startTime: stripTrailingTimezoneText(readString(summary.startTime)),
  };
}

export function stripTrailingTimezoneText(startTime: string): string {
  const match = startTime.match(/^(.*?\b(?:AM|PM)\b).*$/i);
  return (match ? match[1] : startTime).trim();
}

export function parseVtt(vtt: string): ParsedCue[] {
  const normalized = vtt.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  const blocks = normalized.split(/\n[ \t]*\n+/);
  const cues: ParsedCue[] = [];

  for (const rawBlock of blocks) {
    const block = rawBlock.trim();
    if (!block || block.startsWith("WEBVTT") || block.startsWith("NOTE") || block.startsWith("STYLE")) {
      continue;
    }

    const lines = block.split("\n").map((line) => line.trim());
    const timestampIndex = lines.findIndex((line) => line.includes(TIMESTAMP_SEPARATOR));
    if (timestampIndex === -1) {
      continue;
    }

    const textLines = lines.slice(timestampIndex + 1).filter((line) => line.length > 0);
    if (textLines.length === 0) {
      continue;
    }

    const [startRaw, endRaw] = lines[timestampIndex].split(TIMESTAMP_SEPARATOR);
    const startTime = parseVttTimestamp(startRaw);
    const endTime = parseVttTimestamp(endRaw);
    const firstTextLine = textLines[0];
    const colonIndex = firstTextLine.indexOf(":");
    if (colonIndex === -1) {
      throw new Error(`Invalid speaker line: ${firstTextLine}`);
    }

    const speaker = firstTextLine.slice(0, colonIndex).trim();
    const utteranceStart = firstTextLine.slice(colonIndex + 1).trim();
    const continuation = textLines.slice(1).map((line) => line.trim());
    const text = [utteranceStart, ...continuation].filter((line) => line.length > 0).join(" ");

    cues.push({
      startTime,
      endTime,
      duration: endTime - startTime,
      speaker,
      text,
    });
  }

  return cues;
}

export function parseVttTimestamp(timestamp: string | undefined): number {
  if (timestamp === undefined) {
    throw new Error("Expected HH:MM:SS format, got undefined");
  }

  const cleaned = timestamp.trim();
  const parts = cleaned.split(":");
  if (parts.length !== 3) {
    throw new Error(`Expected HH:MM:SS format, got ${timestamp}`);
  }

  const [hoursRaw, minutesRaw, secondsWithMilliseconds] = parts;
  const secondsParts = secondsWithMilliseconds.split(".");
  if (secondsParts.length !== 2) {
    throw new Error(`Expected seconds.milliseconds format, got ${secondsWithMilliseconds}`);
  }

  const [secondsRaw, millisecondsRaw] = secondsParts;
  const hours = parseInteger(hoursRaw, timestamp);
  const minutes = parseInteger(minutesRaw, timestamp);
  const seconds = parseInteger(secondsRaw, timestamp);
  const milliseconds = parseInteger(millisecondsRaw, timestamp);

  if (hours < 0 || hours >= 24) {
    throw new Error(`Hours must be 0-23, got ${hours}`);
  }
  if (minutes < 0 || minutes >= 60) {
    throw new Error(`Minutes must be 0-59, got ${minutes}`);
  }
  if (seconds < 0 || seconds >= 60) {
    throw new Error(`Seconds must be 0-59, got ${seconds}`);
  }

  return hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + milliseconds;
}

function readString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function parseInteger(value: string, timestamp: string): number {
  if (!/^\d+$/.test(value)) {
    throw new Error(`Non-numeric values in timestamp: ${timestamp}`);
  }

  return Number.parseInt(value, 10);
}
