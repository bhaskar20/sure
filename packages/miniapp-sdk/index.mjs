// ESM entry point. The SDK itself is a classic script that installs
// globalThis.SureMiniApp; importing it for its side effect and re-exporting
// keeps one implementation for both loading styles.
import "./sure-miniapp.js";

const SureMiniApp = globalThis.SureMiniApp;

export const connect = SureMiniApp.connect;
export const SureMiniAppError = SureMiniApp.SureMiniAppError;
export const ErrorCodes = SureMiniApp.ErrorCodes;
export const version = SureMiniApp.version;
export const protocolVersion = SureMiniApp.protocolVersion;
export default SureMiniApp;
