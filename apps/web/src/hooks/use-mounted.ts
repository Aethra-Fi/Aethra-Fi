"use client";

import { useSyncExternalStore } from "react";

const subscribe = () => () => {};

/** True only on the client after hydration (avoids theme/wallet hydration mismatches). */
export function useMounted(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => true,
    () => false,
  );
}
