import type { Metadata } from "next";
import { LaunchList } from "@/components/launch/launch-list";

export const metadata: Metadata = { title: "Launch" };

export default function LaunchPage() {
  return (
    <div className="container">
      <LaunchList />
    </div>
  );
}
