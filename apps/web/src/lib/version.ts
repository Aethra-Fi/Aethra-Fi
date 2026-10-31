/** Release shown (as plain text, never a link to the source) in the footer and the landing bar. Set from `version` in apps/web/package.json by next.config.ts;
 *  bump it with each release tag. */
export const APP_VERSION = `v${process.env.NEXT_PUBLIC_APP_VERSION}`;
