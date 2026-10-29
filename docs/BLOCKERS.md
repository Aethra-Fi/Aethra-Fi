# BLOCKERS — hal yang menunggu kamu

Status: `OPEN` = masih menunggu, `DONE` = sudah selesai (dicek ulang di awal sesi).

---

## B1 · Login Supabase CLI — `DONE`

Supabase CLI sudah terpasang (`~/.local/bin/supabase` v2.121.0), tapi belum login. Jalankan:

```bash
# Jalankan di: ROOT
supabase login
```

Perintah ini membuka browser untuk konfirmasi. **Jalankan di terminal biasa di luar Claude Code**: `! supabase login` gagal karena prompt Claude Code bukan TTY (`LoginMissingTokenError`).
Alternatif: buat token di https://supabase.com/dashboard/account/tokens lalu `supabase login --token <token>`, juga di terminal luar (jangan lewat `!`, supaya token tidak masuk log percakapan).
Setelah login, project `aethra-fi-testnet` dan `aethra-fi-mainnet` (region `ap-southeast-1`) akan saya buat sendiri.

## B2 · Import keystore `deployer` — `DONE`

`cast wallet list` hanya menampilkan `alphamarkets-mainnet` dan `hume-mainnet`. Keystore `deployer` belum ada.
Jalankan di terminal kamu sendiri (private key **jangan** ditempel ke chat):

```bash
# Jalankan di: ROOT
cast wallet import deployer --interactive
# Verifikasi: hasilnya harus 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C
cast wallet address --account deployer
```

## B3 · Dana faucet testnet — `DONE`

Saldo `0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C` di Robinhood Chain Testnet = **0 ETH**.
Ambil ETH di https://faucet.testnet.chain.robinhood.com ke alamat itu. Cek:

```bash
# Jalankan di: ROOT
cast balance 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C --rpc-url https://rpc.testnet.chain.robinhood.com -e
```

## B4 · Deploy testnet (butuh password keystore) — `DONE`

Selesai 2026-10-22: 77/77 transaksi sukses, biaya ±0.00052 ETH + 0.005 ETH seed. Semua proxy dimiliki deployer; quote router live berhasil.

Sudah disimulasikan di testnet asli tanpa broadcast: core ±45M gas, maks ±0.0009 ETH; total semua langkah < 0.002 ETH + 0.005 ETH seed likuiditas. Saldo 0.01 ETH cukup.
Jalankan di terminal kamu sendiri (minta password keystore 4×). Langkah pertama memastikan keystore = `0xd09D…9a7C`; jika tidak cocok, script berhenti tanpa deploy apa pun.

```bash
# Jalankan di: ROOT
bash scripts/testnet-deploy.sh
```

Setelah selesai, cukup bilang "B4 selesai": saya baca `packages/contracts/broadcast/` dan `packages/sdk/src/addresses/testnet.json`, lalu commit dan lanjut ke Vercel/Supabase.

## B5 · Region Supabase testnet — `INFO`

Project `Aethra-Fi-testnet` (`zqbnyshzgxhkfxoyrogq`) ada di `ap-northeast-1`, bukan `ap-southeast-1` seperti spesifikasi. Tetap dipakai apa adanya; buat ulang hanya jika kamu mau (project masih kosong).

## B6 · Password database Supabase — `DONE`

Selesai 2026-10-22. File dikunci ke chmod 600. Migrasi, Edge Functions dan cron aktif di testnet; mainnet disiapkan (tanpa secret Vault, jadi cron tidak melakukan apa pun).

Dibutuhkan untuk menjalankan migrasi dan menyimpan secret Vault (cron) di project hosted. Simpan di terminal kamu sendiri, **jangan** di chat:

```bash
# Jalankan di: ROOT
mkdir -p ~/.config/aethra-fi && umask 077 && cat > ~/.config/aethra-fi/supabase.env <<'EOT'
SUPABASE_DB_PASSWORD_TESTNET=...
SUPABASE_DB_PASSWORD_MAINNET=...
EOT
chmod 600 ~/.config/aethra-fi/supabase.env
```

Lupa password? Supabase dashboard → Project Settings → Database → Reset database password.

## B7 · Akses Vercel ke organisasi GitHub `Aethra-Fi` — `DONE`

Selesai 2026-10-22: repo terhubung, production branch `mainnet`, alias `aethra-fi-testnet.vercel.app` → branch `testnet`, live dan publik.

Project Vercel `aethra-fi` sudah dibuat (root `apps/web`, build via turbo, env vars testnet/mainnet terpasang), tapi Vercel tidak bisa melihat repo `Aethra-Fi/Aethra-Fi`.
Buka https://github.com/apps/vercel/installations/new → pilih organisasi **Aethra-Fi** → akses ke repo **Aethra-Fi** (atau All repositories) → Install/Save.
Setelah itu bilang "B7 selesai": saya hubungkan Git, set production branch `mainnet`, dan pasang alias `aethra-fi-testnet.vercel.app` ke branch `testnet`.


## B8 · Matikan sisa wiring fitur tersembunyi di testnet — `DONE`

Kontrak testnet lama (launchpad, credit, buyback) masih ada di chain, dan hub testnet masih menunjuk ke buyback lama dengan protocol fee 20%. Fee protokol DLMM dan hook terus menumpuk ke sana. Untuk memutus: jalankan di terminal sendiri (minta password keystore).

```bash
# Jalankan di: ROOT/packages/contracts
HUB=0x71Bb058106b1a226a6f66e2152719a6B827c783a
LAUNCHPAD=0x498249bC18986216FEC0BECd2f6130D162C970eD
RPC=https://rpc.testnet.chain.robinhood.com
cast send $HUB "setFeeConfig(address,address,uint16)" 0x0000000000000000000000000000000000000000 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C 0 --account deployer --rpc-url $RPC
cast send $HUB "setRegistrar(address,bool)" $LAUNCHPAD false --account deployer --rpc-url $RPC
```

Selain itu, terapkan ke Supabase testnet saat promosi ke branch `testnet`: migrasi `20261026000001_pool_sparkline.sql`, deploy Edge Function `api`, lalu `node supabase/scripts/sync-deployments.mjs testnet` (indexer berhenti membaca kontrak tersembunyi).

Selesai 2026-10-26: `buyback()` = 0x0, `protocolFeeShareBps()` = 0, treasury = deployer, launchpad lama bukan registrar lagi (DLMM factory tetap registrar). Migrasi sparkline, Edge Function `api`, dan sync deployments sudah diterapkan ke Supabase testnet.

## B9 · DNS `aethra.finance` di Hostinger — `DONE`

Domain sudah ditambahkan ke project Vercel `aethra-fi` (2026-10-28), tapi DNS masih menunjuk ke parking Hostinger. Ubah di hPanel → Domains → aethra.finance → DNS / Nameservers → DNS records:

| Type | Name | Value | Aksi |
|---|---|---|---|
| A | `@` | `216.198.79.1` | ganti A lama `2.57.91.91` |
| CNAME | `www` | `21ffe789fcdae145.vercel-dns-017.com.` | ganti CNAME lama ke `aethra.finance` |
| CNAME | `testnet` | `21ffe789fcdae145.vercel-dns-017.com.` | baru |

Hapus record AAAA parking untuk `@` dan `www` jika ada. Setelah itu bilang "B9 selesai": saya cek `vercel api /v6/domains/<host>/config` dan sertifikat SSL.

Selesai 2026-10-28: DNS benar, `testnet.aethra.finance` dan `aethra.finance` HTTPS 200, `www` redirect 308. Sertifikat apex perlu `vercel certs issue aethra.finance` manual.

## B10 · Upgrade kontrak testnet dengan fix keamanan — `DONE` 2026-10-30

Selesai: 6 transaksi sukses (3 deploy implementasi + 3 `upgradeToAndCall`), 8,35M gas. Alamat implementasi ada di `docs/infrastructure.md`. Teks di bawah adalah catatan asli.

Kontrak testnet masih implementasi lama tanpa fix keamanan 2026-10-30 (router R-1..R-3, hook H-1, hub H-2). Upgrade mengganti hub, hook, dan router lewat proxy yang sama. Alamat tidak berubah.

Sudah diverifikasi tanpa broadcast:
- Referensi (`packages/contracts/upgrades/v0-testnet`) dibangun dari commit `3be51c6` dan cocok byte-per-byte dengan kode on-chain (hub, hook, router, positions, factory, limit orders).
- Validasi OpenZeppelin (layout storage dan keamanan upgrade) lolos untuk ketiganya. Uji negatif: field yang disisipkan di storage hub ditolak.
- Simulasi di testnet live: 3 deploy implementasi + 3 upgrade, ≈ 0,00022 ETH. Saldo deployer 0,0045 ETH.
- Tes fork (`FORK_TESTNET=1 forge test --match-path test/fork/TestnetUpgrade.t.sol`): quote semua pool sama sebelum dan sesudah upgrade, swap WETH nyata lolos, state hub utuh.

Jalankan di terminal kamu sendiri (minta password keystore dua kali: verifikasi alamat, lalu broadcast):

```bash
# Jalankan di: ROOT
bash scripts/testnet-upgrade.sh --broadcast
```

Script berhenti tanpa mengirim apa pun bila keystore `deployer` bukan `0xd09D…9a7C`. Setelah selesai cukup bilang "B10 selesai": aku baca `packages/contracts/broadcast/Upgrade.s.sol/46630/`, cek `implementation()` tiga proxy, jalankan ulang tes fork terhadap state baru, dan perbarui `docs/infrastructure.md`.

Catatan: jangan jalankan script ini dengan commit yang berbeda dari yang diuji. Fix keamanan belum di-commit saat B10 ditulis. Commit dulu, lalu jalankan.
