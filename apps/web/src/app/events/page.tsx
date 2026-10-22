import type { Metadata } from "next";
import { EventsView } from "@/components/data/events-view";

export const metadata: Metadata = { title: "Event feed" };

export default function Page() {
  return (
    <div className="container">
      <EventsView />
    </div>
  );
}
