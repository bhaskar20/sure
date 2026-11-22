export const S = {
  title: "Connect to your Sure server",
  serverLabel: "Server address",
  urlPlaceholder: "https://sure.example.com",
  connect: "Continue",
  checking: "Checking server…",
  unreachable: "Couldn't reach a Sure server at that address.",
  invalidUrl: "That doesn't look like a valid address.",
  remembered: "Remembered servers",
  remove: "Remove",
  localTitle: "Starting Sure",
  devAccountsTitle: "Sign in as",
  devAccountsEmpty: "No accounts yet. Create one, or run npm run seed:dev.",
  devSkip: "Continue without signing in",
  localFailed: "Sure couldn't start",
  localLogs: "Logs are in:",
} as const;

export const P = {
  title: "Preferences",
  servers: "Servers",
  add: "Add",
  launchAtLogin: "Launch Sure at login",
  switchTo: "Switch to",
} as const;

export const AI = {
  title: "Local AI",
  moved: "Choose, download and run local AI models in Sure under Settings → Local AI.",
} as const;

export const U = {
  title: "Updates",
  check: "Check for Updates",
  checking: "Checking for updates…",
  current: (v: string) => `Sure ${v}`,
  upToDate: (v: string) => `Sure ${v} is up to date.`,
  available: (latest: string, v: string) =>
    `Sure ${latest} is available (you have ${v}). Download it, quit Sure, then drag the new Sure into Applications and choose Replace. Your data is kept.`,
  download: (latest: string) => `Download Sure ${latest}`,
  installable: (latest: string, v: string) =>
    `Sure ${latest} is available (you have ${v}). Sure installs it and restarts; your data is kept.`,
  install: (latest: string) => `Install Sure ${latest} and Restart`,
  installing: (latest: string, percent: number | null) =>
    percent === null ? `Downloading Sure ${latest}…` : `Downloading Sure ${latest}… ${percent}%`,
  installFailed: (latest: string, error: string) => `Couldn't install Sure ${latest}: ${error}`,
  failed: (v: string) => `Sure ${v}. Couldn't check for updates; try again later.`,
  disabled: (v: string) => `Sure ${v}. This build doesn't check for updates.`,
} as const;
