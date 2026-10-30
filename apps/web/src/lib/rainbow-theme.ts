import { darkTheme, lightTheme, type Theme } from "@rainbow-me/rainbowkit";

const v = (name: string, a?: number) => (a === undefined ? `rgb(var(--${name}))` : `rgb(var(--${name}) / ${a})`);

/** RainbowKit theme bound to Aethra CSS variables, so it follows the active theme automatically. */
export function rainbowTheme(mode: "dark" | "light"): Theme {
  const base = (mode === "dark" ? darkTheme : lightTheme)({
    accentColor: v("primary"),
    accentColorForeground: v("primary-fg"),
    borderRadius: "none",
    fontStack: "system",
    overlayBlur: "small",
  });
  return {
    ...base,
    colors: {
      ...base.colors,
      modalBackground: v("surface"),
      modalBorder: v("border"),
      modalText: v("text"),
      modalTextDim: v("muted"),
      modalTextSecondary: v("muted"),
      modalBackdrop: v("bg", 0.7),
      generalBorder: v("border"),
      generalBorderDim: v("border", 0.6),
      menuItemBackground: v("surface-2"),
      actionButtonBorder: v("border"),
      actionButtonBorderMobile: v("border"),
      actionButtonSecondaryBackground: v("surface-2"),
      closeButton: v("muted"),
      closeButtonBackground: v("surface-2"),
      connectButtonBackground: v("surface"),
      connectButtonInnerBackground: v("surface-2"),
      connectButtonText: v("text"),
      profileAction: v("surface-2"),
      profileActionHover: v("border"),
      profileForeground: v("surface"),
      selectedOptionBorder: v("primary"),
      standby: v("warning"),
      error: v("danger"),
      connectionIndicator: v("primary"),
    },
    fonts: { body: "var(--font-geist-mono), ui-monospace, SFMono-Regular, monospace" },
    radii: { ...base.radii, actionButton: "2px", connectButton: "2px", menuButton: "2px", modal: "0px", modalMobile: "0px" },
    shadows: { ...base.shadows, dialog: "none", connectButton: "none", profileDetailsAction: "none", selectedOption: "none", selectedWallet: "none", walletLogo: "none" },
  };
}
