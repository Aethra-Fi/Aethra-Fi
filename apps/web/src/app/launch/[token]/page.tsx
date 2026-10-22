import { notFound } from "next/navigation";
import { isAddress } from "viem";
import { LaunchDetail } from "@/components/launch/launch-detail";

export default async function LaunchTokenPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  if (!isAddress(token)) notFound();
  return (
    <div className="container">
      <LaunchDetail token={token} />
    </div>
  );
}
