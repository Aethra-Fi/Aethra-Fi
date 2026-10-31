/** Release shown in the footer and the landing bar. Set from `version` in apps/web/package.json by next.config.ts;
 *  bump it with each release tag. */
export const APP_VERSION = `v${process.env.NEXT_PUBLIC_APP_VERSION}`;
export const RELEASE_URL = `https://github.com/Aethra-Fi/Aethra-Fi/releases/tag/${APP_VERSION}`;
