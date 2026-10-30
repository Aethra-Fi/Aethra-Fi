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

## B11 · Likuiditas testnet + perbaikan pool saham (butuh password keystore) · `DONE` 2026-10-30

Selesai: feed segar, quote hidup di semua venue (1.000 aUSD → 3,95 aTSLA di v4, 3,98 di DLMM), indexer membaca 7 pool dengan TVL ±$828k. Teks di bawah adalah catatan asli.

Saat ini semua pool saham di testnet berhenti karena mock price feed-nya basi. Batch ini menyegarkan feed, memperdalam pool, dan membuka pool DLMM dan DAMM pertama. Biaya ±0,00012 ETH gas plus 0,003 ETH yang di-wrap jadi likuiditas. Saldo testnet 0,0044 ETH. Untuk WETH/aUSD yang lebih dalam, isi dulu dari faucet lalu set `SEED_WETH` (wei).

```bash
# Jalankan di: ROOT
bash scripts/testnet-liquidity.sh             # simulasi saja
bash scripts/testnet-liquidity.sh --broadcast # 2x prompt password
```

Setelah itu bilang "B11 selesai". Aku cek indexer, quote di semua venue, dan halaman faucet.

## B15 · Redeploy testnet dengan metadata hash (butuh password keystore) · `DONE` 2026-10-30

Selesai: 117 transaksi sukses, indexer membaca 7 pool baru (TVL ±$828k), uji exact match pada mock feed aUSD baru `0x631b…a4c2` lolos ("Contract source code verified (exact match)", lisensi MIT). Teks di bawah adalah catatan asli.

Supaya explorer menampilkan "Contract source code verified (exact match)", bukan "partial match". Semua alamat testnet berubah. Web, SDK, dan indexer aku perbarui setelahnya.

1. Isi saldo testnet dari https://faucet.testnet.chain.robinhood.com. Sisa saldo 0,0013 ETH; script butuh minimal 0,003 ETH (gas ±0,0006 ETH + seed WETH 0,001 ETH).
2. Jalankan (password diminta sekali):

```bash
# Jalankan di: ROOT
bash scripts/testnet-redeploy.sh --broadcast
```

Setelah itu bilang "B15 selesai". Aku membersihkan data indexer lama, sync alamat baru ke Supabase, promosikan web ke `testnet`, lalu membuktikan exact match dengan memverifikasi satu mock feed (bukan bagian dari rekaman).

## B16 · Redeploy testnet sekali lagi (butuh password keystore) · `DONE` 2026-10-30

Selesai: 117 transaksi sukses, 32/32 paket verifikasi (semuanya paket kecil) cocok dengan bytecode di chain. Indexer sudah di-sync ke alamat baru. Teks di bawah adalah catatan asli.

Rekaman pertama: 31 dari 32 kontrak sebenarnya exact match ("Unknown UID" hanya tiket status yang hilang di explorer). DLMM pool implementation gagal: bytecode-nya cuma bisa direproduksi dengan paket ±160 file, yang butuh 67 detik untuk dikompilasi, dan explorer menyerah. Sekarang DLMM pool di-deploy dari bytecode paket kecilnya (17 file, 2 detik), jadi yang di-deploy sama dengan yang diverifikasi. Script verifikasi juga tidak lagi menganggap "Unknown UID" sebagai gagal. Sudah dicoba di fork: 32/32 paket cocok.

Supaya rekaman fresh lagi (32/32 "verified"), deploy ulang testnet. Password diminta sekali. Saldo cukup (butuh 0,003 ETH).

```bash
# Jalankan di: ROOT
bash scripts/testnet-redeploy.sh --broadcast
```

Setelah itu bilang "B16 selesai".

## B12 · Rekam layar verifikasi testnet · `DONE` 2026-10-30

Selesai: 32/32 kontrak "exact match" dengan lisensi MIT di explorer testnet. Link ada di `docs/verification/testnet.md`. Teks di bawah adalah catatan asli.

Tidak butuh keystore. 32 kontrak, semua tampil fresh di rekaman.

```bash
# Jalankan di: ROOT
export PS1='$ '
clear
# mulai rekam, lalu:
bash scripts/verify-contracts.sh testnet
```

Di layar: cek koneksi, tekan Enter, 32 kontrak diverifikasi satu per satu (spinner lalu ✓), bukti dari explorer dengan label "exact match" dan link yang bisa diklik, lalu prompt untuk membuka kontrak di browser (ketik nomor, `q` selesai). Halaman explorer menampilkan "Contract source code verified (exact match)". Link juga disimpan di `docs/verification/testnet.md`.

## B17 · Probe verifikasi mainnet (butuh password keystore) · `DONE` 2026-10-31

Selesai: `VerificationProbe` `0x549046a186026dd79c5a91cda4844097ba13713a` di mainnet. Sourcify `exact_match`, dan explorer mainnet menampilkan "Contract source code verified (exact match)" (dicek kamu di browser). Teks di bawah adalah catatan asli.

API explorer mainnet menolak semua klien terminal (tantangan browser Cloudflare), VPN pun tetap 403. Jadi verifikasi mainnet lewat Sourcify, yang memverifikasi lalu meneruskan ke explorer dari server mereka. Di testnet jalur ini sudah terbukti: Sourcify `exact_match`, dan explorer menampilkan "verified (exact match)". Satu-satunya yang belum terbukti adalah penerusan ke explorer **mainnet**. Probe ini membuktikannya dengan satu kontrak mini (`VerificationProbe`, ±127k gas, < $0,01).

```bash
# Jalankan di: ROOT
bash scripts/mainnet-verify-probe.sh   # password diminta sekali
```

Buka link yang dicetak di browser. Halamannya harus menampilkan "Contract source code verified (exact match)". Bilang "B17 selesai" beserta apa yang terlihat di halaman itu.

## B13 · Deploy mainnet (butuh password keystore) · `DONE` 2026-10-31

Selesai: 38 transaksi sukses, gas 43,24 juta, biaya 0,00087 ETH (±$1,92). Semua kunci on-chain sesuai rencana. 28/28 paket verifikasi cocok. Indexer di-sync, web dipromosikan ke `mainnet`. Teks di bawah adalah catatan asli.

Status 2026-10-30: invariant test DLMM dan DAMM lolos. 28 paket verifikasi mainnet sudah dibuktikan terhadap dry run, termasuk metadata hash (exact match). Dry run terakhir $2,49.

Satu script untuk seluruh rilis: core, DLMM, DAMM hidup, sedangkan launchpad, AETH, buyback, dan kredit terkunci on-chain. Owner = deployer. Dry run 2026-10-30: ±$1,89 (batas atas $2,44). Forge butuh ±0,00218 ETH di muka, saldo 0,00297 ETH. Kalau harga gas di atas ±0,05 gwei, tunggu turun.

```bash
# Jalankan di: ROOT
bash scripts/mainnet-deploy.sh              # dry run + laporan biaya, tidak mengirim apa pun
bash scripts/mainnet-deploy.sh --broadcast  # 2x prompt password; menulis packages/sdk/src/addresses/mainnet.json
```

Setelah itu bilang "B13 selesai". Lalu aku:
- commit `mainnet.json` (tombol Mainnet di web otomatis aktif),
- hubungkan indexer Supabase mainnet (sync deployments, Vault secrets, cron),
- promosikan `main` ke `mainnet` (Vercel production `aethra.finance`),
- smoke test.

## B18 · Kunci v1.1 di mainnet (butuh password keystore) · `OPEN`

DLMM, DAMM, dan limit orders ikut terbuka saat deploy, padahal rencananya rilis v1.1. Script ini mencabut status registrar kedua factory: 2 transaksi, ±79k gas, ±$0,004, password diminta sekali. Sudah disimulasikan di mainnet. Web otomatis menyembunyikan DLMM/DAMM/limit orders setelahnya.

```bash
# Jalankan di: ROOT
bash scripts/mainnet-v11.sh lock
```

Saat v1.1 rilis: `bash scripts/mainnet-v11.sh open`.

## B19 · Launch v1.0: top-up lalu seed WETH/USDG (butuh password keystore) · `OPEN`

1. Kirim ke deployer `0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C` di Robinhood Chain: **±0,004 ETH** (saldo sekarang 0,0021 ETH; dibutuhkan 0,005 seed + 0,0001 smoke test + 0,0003 cadangan gas) dan **±11,5 USDG** (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`; saldo sekarang 0,12).
2. Jalankan:

```bash
# Jalankan di: ROOT
bash scripts/mainnet-launch-v1.sh
```

Script mengambil harga ETH dari CoinGecko, menampilkan jumlah seed, dan menunggu konfirmasi `y` serta password (sekali). Lalu script membuka pool WETH/USDG, mengisi posisi full-range, dan menjalankan smoke test swap 0,0001 ETH → USDG. Sudah dilatih di fork mainnet (`FORK_MAINNET=1 forge test --match-path test/fork/MainnetLaunch.t.sol`).

Tombol darurat bila perlu: `bash scripts/mainnet-pool-switch.sh off` (swap ditolak, likuiditas tetap bisa ditarik), `... on` untuk menyalakan lagi.

## B20 · Terbitkan SDK ke npm · `OPEN`

Paket sudah siap (`packages/sdk`: README, metadata, `viem` sebagai peer, `npm pack` 47,6 kB, 9 test).

1. Buat organisasi npm `aethra` di https://www.npmjs.com/org/create. Kalau nama itu sudah dipakai, kabari aku untuk mengganti nama paket (misalnya `@aethra-fi/sdk`).
2. Jalankan di terminalmu sendiri:

```bash
# Jalankan di: ROOT/packages/sdk
npm login
npm publish
```

`prepublishOnly` menjalankan build dan test terlebih dulu. Setelah terbit, bilang "B20 selesai": aku tambahkan baris install di halaman Developers.

## B14 · Rekam layar verifikasi mainnet · `DONE` 2026-10-31

Selesai: 28/28 kontrak mainnet exact match lewat Sourcify (rekaman kamu). Teks di bawah adalah catatan asli.

VPN tidak diperlukan: untuk mainnet script otomatis memakai Sourcify. Paket verifikasi disiapkan otomatis oleh `mainnet-deploy.sh --broadcast`. Kabari aku dulu setelah B13 supaya aku cek paketnya.

```bash
# Jalankan di: ROOT
export PS1='$ '
clear
bash scripts/verify-contracts.sh mainnet
```

Link disimpan di `docs/verification/mainnet.md`.
