import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { LaunchList } from "@/components/launch/launch-list";
import { FEATURES } from "@/lib/features";

export const metadata: Metadata = { title: "Launch" };

export default function LaunchPage() {
  if (!FEATURES.launchpad) notFound();
  return (
    <div className="container">
      <LaunchList />
    </div>
  );
}
