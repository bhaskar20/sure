// Writes a release version into tauri.conf.json, which sets the version the
// built app reports (About box, update checks) and the installer file names.
// Usage: node desktop/scripts/stamp-version.mjs 0.1.42
import { readFileSync, writeFileSync } from "node:fs";

const version = process.argv[2];
if (!/^\d+\.\d+\.\d+$/.test(version ?? "")) {
  console.error(`invalid version: ${version}`);
  process.exit(1);
}
const file = new URL("../src-tauri/tauri.conf.json", import.meta.url);
const config = JSON.parse(readFileSync(file, "utf8"));
config.version = version;
writeFileSync(file, `${JSON.stringify(config, null, 2)}\n`);
console.log(`Sure Desktop version ${version}`);
