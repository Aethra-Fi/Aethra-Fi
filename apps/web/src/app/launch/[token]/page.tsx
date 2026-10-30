import { notFound } from "next/navigation";
import { isAddress } from "viem";
import { LaunchDetail } from "@/components/launch/launch-detail";
import { FEATURES } from "@/lib/features";

export default async function LaunchTokenPage({ params }: { params: Promise<{ token: string }> }) {
  if (!FEATURES.launchpad) notFound();
  const { token } = await params;
  if (!isAddress(token)) notFound();
  return (
    <div className="container">
      <LaunchDetail token={token} />
    </div>
  );
}
