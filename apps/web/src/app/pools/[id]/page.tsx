import { PoolDetail } from "@/components/pools/pool-detail";

export default async function PoolPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return (
    <div className="container">
      <PoolDetail poolId={decodeURIComponent(id)} />
    </div>
  );
}
