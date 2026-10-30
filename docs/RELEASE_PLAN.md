# Rencana rilis mainnet: Aethra Fi

Disusun 2026-10-30, direvisi hari yang sama. Cakupan: urutan fitur, syarat teknis, biaya gas, dan langkah operasional. Narasi dan konten X tidak dibahas di sini.

> **Revisi 2026-10-30 (keputusan kamu):** owner mainnet = wallet deployer (tanpa Safe dulu), semua modul di-deploy sekaligus lewat `script/DeployMainnet.s.sol` (`scripts/mainnet-deploy.sh`), tanpa seed likuiditas sampai ada top-up. Stablecoin = USDG `0x5fc5…d168`, token saham terkunci = TSLA, NVDA, AAPL resmi. Pembukaan modul dikirim langsung oleh deployer, bukan Safe. Dry run final: 42,1 juta gas ≈ $1,89 (rincian di `PROGRESS.md`).

> **Status mainnet 2026-10-31 (setelah B13):**
>
> | Rilis | Isi | Status |
> |---|---|---|
> | v1.0 | v4 + hook, router, positions, analytics, docs, API, SDK | Hidup. Diluncurkan **tanpa seed** (keputusan 2026-10-31: budget $7 hanya untuk gas). Seed WETH/USDG menyusul saat ada dana (`scripts/mainnet-launch-v1.sh`, B19). SDK siap terbit (B20). |
> | v1.1 | DLMM + limit orders + DAMM | Terbuka saat deploy, dikunci lagi dengan `bash scripts/mainnet-v11.sh lock` (B18). Dibuka dengan `bash scripts/mainnet-v11.sh open`. Web membaca `hub.isRegistrar(factory)`, jadi ikut tampil atau tersembunyi tanpa redeploy. |
> | v1.2 | Stock pools + oracle guard | Terkunci: TSLA, NVDA, AAPL `STOCK` dan dinonaktifkan. |
> | v1.3 | Launchpad, fee ke treasury | Terkunci (bukan registrar). **Sebelum dibuka:** DLMM pool dan hook v4 hanya bisa menyapu protocol fee ke kontrak buyback (DAMM sudah bisa ke treasury). "Fee ke treasury dulu" butuh upgrade DLMM pool (beacon) dan hook (UUPS) dengan fallback ke treasury, atau fee share tetap 0 sampai v1.4. |
> | v1.4 | AETH + pool AETH + buyback | Buyback terkunci (fee share 0). Token AETH sudah ada di chain, 1 miliar di deployer. |
> | v2.0 | Credit | Terkunci: vault tanpa credit manager, cap 0. |
>
> Source code semua 28 kontrak mainnet diterbitkan saat B14 (keputusan kamu, bukan ditunda per modul).

## 1. Model rilis

**Deploy sekali, buka bertahap.** Semua kontrak yang siap di-deploy sekaligus (Batch A, dan Batch B bila syaratnya terpenuhi). Fitur yang belum waktunya dikunci **di on-chain**, bukan hanya disembunyikan di UI, lalu dibuka satu per satu lewat satu batch transaksi Safe ditambah satu flag.

Flag UI tidak melindungi dana. Semua kontrak permissionless, jadi siapa pun bisa memanggilnya langsung dari explorer. Kunci on-chain per modul:

| Modul | Kunci sampai dibuka | Cara buka (Safe) |
|---|---|---|
| DLMM, DAMM, limit orders | Factory bukan registrar. `createPool` memanggil `hub.registerPool` dan revert `NotRegistrar`. | `hub.setRegistrar(factory, true)` |
| Launchpad | Launchpad bukan registrar. `create` revert di `registerPool`. | `hub.setRegistrar(launchpad, true)` |
| Stock pools | Token saham terdaftar `STOCK`, `enabled=false`, oracle nol. Hook menolak initialize pool saham (bagian 3, item 4). | `hub.setAsset(token, STOCK, true, feed, maxStaleness)` |
| Buyback | `hub.setFeeConfig(0, treasury, 0)`, jadi share 0. | `hub.setFeeConfig(buyback, treasury, 2000)` |
| Kredit | Bawaan vault: `supplyCap` dan `borrowCap` = `type(uint256).max` (terbuka). Script deploy memanggil `setCaps(0, 0)`. `vault.setCreditManager` tidak dipanggil, jadi `lend` revert `onlyCreditManager`. | `setCaps(...)`, `vault.setCreditManager(cm)` |

Satu pembukaan ≈ 0,1 juta gas dan tanpa prompt keystore.

Alamat modul tersembunyi masuk objek `hidden` di `packages/sdk/src/addresses/mainnet.json` (mekanisme yang sudah dipakai di testnet) dan dipindah ke atas saat dibuka.

## 2. Asumsi dan budget

- **Budget $7–8 = biaya gas on-chain seluruh rilis.** Modal seed likuiditas dan modal vault kredit dihitung terpisah.
- Harga gas mainnet 0,02076 gwei (`eth_gasPrice`, 2026-10-30). ETH $2.337,31 (CoinGecko, hari yang sama).
- Biaya komponen L1 = 0 menurut NodeInterface (`gasEstimateL1Component`) pada 2026-10-30. Cek ulang sebelum setiap broadcast.
- Saldo deployer mainnet: 0,00298 ETH (≈ $6,97).
- Angka core, DLMM, dan DAMM berasal dari dry run mainnet 2026-10-30 (26,23 juta gas). Angka launchpad, AETH, buyback, dan kredit berasal dari pengukuran fork testnet di `PROGRESS.md` (2026-10-22) dengan margin 5%. Angka seed, wiring Safe, dan cadangan adalah estimasi. Ukur ulang dengan dry run mainnet sebelum broadcast.

| Tahap | Isi | Gas (juta) | $ pada 0,0208 gwei | $ pada 2× | $ pada 4× |
|---|---|---|---|---|---|
| Batch A | Core, DLMM + limit orders, DAMM, launchpad, Safe, kunci on-chain, seed pool v1.0 | 35,9 | 1,74 | 3,48 | 6,96 |
| Batch B | AETH + buyback + kredit (bersyarat, bagian 4) | 10,9 | 0,53 | 1,06 | 2,11 |
| Pembukaan | Wiring Safe dan seed pool per modul, oracle saham | 10,5 | 0,51 | 1,02 | 2,04 |
| Cadangan | Satu putaran upgrade router, positions, hook (10,5) dan operasi keeper (3,0) | 13,5 | 0,66 | 1,31 | 2,62 |
| **Total** | | **70,8** | **3,44** | **6,87** | **13,73** |

Total muat di $7–8 sampai harga gas naik sekitar 2×. Karena Batch A dibayar di muka, jadwalkan deploy saat gas rendah. Pada 4× Batch A saja hampir $7.

## 3. Prasyarat deploy (gerbang deploy)

**Kontrak. Status per 2026-10-30:**

1. ✅ Fix router R-1..R-3: hop non-v4 wajib menyebut kontrak yang didaftarkan hub untuk id dan venue itu, aktif; approval di-reset ke 0 setelah hop. `quote` memakai pemeriksaan yang sama.
2. ✅ Fix hook H-1: pool `ORACLE` revert saat initialize bila oracle tidak fresh atau harga awal di luar `maxDeviationBps`.
3. ✅ Fix hub H-2: `setAsset` menolak `maxStaleness == 0` bila oracle diisi (`InvalidStaleness`).
4. ✅ Guard saham: aset `STOCK` yang belum `enabled` tidak bisa dipakai di pool (`AssetNotEnabled`). Daftarkan semua token saham mainnet saat Batch A sebagai `STOCK`, `enabled=false`, oracle nol.
5. ✅ 190 tes forge hijau, termasuk tes regresi di `test/security/RouterHookAudit.t.sol`.
6. ✅ Invariant test DLMM dan DAMM (2026-10-30, `test/dlmm/DLMM.invariant.t.sol`, `test/damm/DAMM.invariant.t.sol`) (saldo token pool ≥ total klaim LP dan fee). Wajib sebelum DLMM/DAMM dibuka. Disarankan sebelum deploy.
7. ⬜ Script deploy gabungan dengan env `OWNER`. Modul baru (beacon, factory, limit orders, launchpad, vault) di-initialize dengan Safe sebagai owner. Core dimiliki deployer sampai wiring selesai, lalu `transferOwnership` ke Safe.
8. ⬜ `setCaps(0, 0)` dan tanpa `setCreditManager` di script kredit.
9. ⬜ Pecah `DeployLaunchpadBuyback` menjadi dua script: launchpad (Batch A) dan AETH + buyback (Batch B).
10. ✅ Tooling upgrade: `scripts/snapshot-build.sh`, `scripts/upgrade.sh`, `packages/contracts/script/upgrade/Upgrade.s.sol`. Validasi layout storage dan keamanan lewat OpenZeppelin terhadap build referensi, deploy implementasi baru, upgrade langsung (testnet) atau calldata untuk Safe (mainnet). Mendukung 13 target (proxy UUPS dan beacon pool).
11. ✅ Toggle jaringan di web: pengunjung memilih Testnet atau Mainnet di header, pilihan disimpan di browser. Tombol mainnet aktif sendiri saat `hub` terisi di `addresses/mainnet.json`.
12. ✅ B10: kontrak testnet (hub, hook, router) sudah di-upgrade dengan fix di atas (2026-10-30).

**Infrastruktur**

10. Safe multisig di Robinhood Chain. Singleton dan factory kanonik punya kode di mainnet (dicek 2026-10-30: `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67`, `0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2`). Verifikasi alamat di explorer. Dukungan UI Safe untuk chain ini belum dicek; kalau belum ada, kirim transaksi lewat `safe-cli` atau skrip.
11. Supabase mainnet: Vault secrets (`project_url`, `indexer_token`), function secret `INDEXER_TOKEN`, cron, `sync-deployments.mjs mainnet`, `startBlock` dari receipt L2 (`set-start-block.mjs`).
12. ✅ Sertifikat apex `aethra.finance`: Let's Encrypt, berlaku sampai 2027-01-26 (dicek 2026-10-30). DNS di Hostinger sudah menunjuk ke Vercel (B9).
13. SDK `@aethrafi/sdk`: klaim scope npm, hapus `private: true`, terbitkan v0.1.0 (halaman `/developers` merujuk SDK).
14. Flag UI dan API per modul (`dlmm`, `damm`, `orders`, `stock`, `launchpad`, `credit`, `buyback`). Verifikasi dulu apakah alamat `hidden` sudah menyembunyikan fitur otomatis.
15. Verifikasi Blockscout ditunda untuk modul tersembunyi sampai dibuka (opsional, mengurangi kebocoran peta jalan).

**Data dari kamu**

16. Alamat stablecoin mainnet, token saham mainnet, penanda tangan Safe dan threshold (usulan 2 dari 3), alamat holder AETH (usulan: Safe), dan top-up ETH ke deployer.

## 4. Batch B: syarat bersyarat

Batch A tidak menunggu Batch B. Deploy AETH + buyback dan kredit bersama Batch A hanya bila syarat ini sudah pasti. Kalau belum, jalankan sebagai batch kecil kedua.

- **AETH + buyback.** `AethraToken` mencetak 1 miliar AETH sekaligus ke satu `holder` tanpa owner dan tanpa fungsi mint, jadi `holder` dan skema distribusi harus diputuskan lebih dulu (usulan: `holder` = Safe).
- **Kredit.** Aset vault tidak bisa diganti setelah `initialize`. Stablecoin mainnet harus final.

## 5. Template operasional

Dipakai di setiap tahap deploy dan pembukaan.

1. **Freeze dan tes.** `forge test`, `pnpm lint`, `pnpm typecheck`, `pnpm test`, Playwright.
2. **Latihan di testnet.** Script yang sama persis, termasuk serah-terima dan pembukaan.
3. **Dry run mainnet.** `forge script … --rpc-url mainnet` tanpa `--broadcast`. Catat gas dan USD di `PROGRESS.md`. Hentikan bila lebih dari 30% di atas estimasi tabel.
4. **Broadcast oleh kamu.** Perintah lengkap dengan direktori di `docs/BLOCKERS.md`. Script memeriksa `cast wallet address --account deployer` = `0xd09D…9a7C` sebelum deploy.
5. **Catat alamat.** `Deploy.s.sol` tidak menulis `mainnet.json` untuk mainnet. Baca `broadcast/…/4663/run-latest.json`, isi alamat proxy dan `startBlock`.
6. **Serah-terima ke Safe.** `transferOwnership` lalu `acceptOwnership` (`Ownable2Step`). Beacon satu langkah. Cek `owner()` tiap kontrak.
7. **Indexer dan API.** `sync-deployments.mjs mainnet`, tunggu `indexer_state.status = ok`, cek `/api/health`.
8. **Smoke test.** Swap kecil, tambah dan tarik likuiditas kecil, cek event di feed.
9. **Pantau 48 jam.** Siapkan `setPoolEnabled(false)` dan `setRegistrar(…, false)` di Safe sebagai tombol darurat.
10. **Catat.** `PROGRESS.md` (status, biaya aktual vs estimasi) dan `infrastructure.md`.

Pembukaan modul (langkah 3–10 saja): gerbang modul lolos → batch Safe → seed pool → naikkan versi SDK dan aktifkan flag → smoke test → pantau.

## 6. Daftar pembukaan per modul

Urutan buka: v4 core (langsung hidup di Batch A) → DLMM + DAMM + limit orders → stock pools → launchpad → AETH + buyback → kredit.

### Core v4 (hidup di Batch A)

- **Isi.** `AethraHub`, `AethraHook` (CREATE2), `AethraRouter`, `AethraPositions`. UI swap, pools, create pool v4, positions + lock, analytics, event feed, contracts, docs, developers. SDK dan API.
- **Wiring sebelum serah-terima.** `setRegistrar(hook)`, `setFeeConfig(0, treasury, 0)`, `setAsset` WETH dan stablecoin (`CANONICAL`, oracle mainnet, `maxStaleness` > 0), `setAsset` semua token saham (`STOCK`, `enabled=false`, oracle nol).
- **Seed.** Pool WETH/stablecoin (mode `DYNAMIC`) dan satu atau dua pasangan lain. Router tanpa pool berlikuiditas membuat swap gagal. Estimasi 1 juta gas per pool.
- **Gerbang.** Prasyarat 1–5 dan 10–14 selesai, smoke test lolos, indexer `ok`.

### DLMM + limit orders + DAMM

- **Buka.** `hub.setRegistrar(dlmmFactory, true)` dan `hub.setRegistrar(dammFactory, true)` lewat Safe.
- **Seed.** Satu pool DLMM dan satu pool DAMM (≈ 1,5 juta gas).
- **Gerbang.** Invariant test DLMM dan DAMM hijau. Fuzz limit order: klaim tidak melebihi deposit. Tes fork mainnet: quote router lewat venue baru sesuai hitungan manual.
- **Risiko.** Matematika AMM kustom, dan limit orders memegang dana. Mulai dengan likuiditas kecil.

### Stock pools + oracle guard

- **Syarat keras.** Feed mainnet terverifikasi: alamat, `decimals()`, interval update, perilaku jam pasar. Feed tanpa `isMarketOpen()` berarti pengganda fee saat pasar tutup tidak berfungsi. Putuskan dulu apakah itu bisa diterima.
- **Buka.** `setAsset(token, STOCK, true, feed, maxStaleness)` per token (≈ 0,1 juta gas). Tanpa kontrak baru bila feed mengikuti `IAggregatorV3`; adaptor kira-kira 0,3 juta gas per feed.
- **Seed.** Pool saham/stablecoin mode `ORACLE`, harga awal dalam band oracle (initialize di luar band akan revert). Mulai dari tiga pool.
- **Gerbang.** Tes fork: quote terhadap feed asli, breaker tidak menyala pada harga wajar, swap berhenti saat feed dimatikan.
- **Risiko.** Ketergantungan oracle. Swap berhenti saat feed basi (fail-closed). Tentukan prosedur bila feed mati lebih dari satu sesi.

### Launchpad

- **Buka.** `setRegistrar(launchpad, true)`, `setGraduationTargets(poolManager, positions, hook)`, parameter kurva dan fee. Setter kurva dan fee masih bisa diubah owner.
- **Tinjau parameter.** Virtual reserves, ambang graduation, dan fee jangan memakai nilai testnet. Tulis angka final di dokumen ini.
- **Gerbang.** Invariant: WETH terkumpul konsisten dengan integral kurva dikurangi fee. Tes fork: graduation ke pool v4 berhasil.
- **Risiko.** Kurva kustom yang memegang dana. Graduation menghasilkan likuiditas terkunci permanen.

### AETH + buyback & burn

- **Urutan.** (1) Deploy `AethraToken`. (2) Buat dan seed pool AETH/WETH (tanpa ini `execute()` tidak punya rute). (3) Deploy `AethraBuyback`. (4) `hub.setFeeConfig(buyback, treasury, 2000)` terakhir.
- **Keeper.** `execute()` punya cooldown dan error `NotKeeper`. Tentukan alamat keeper dan siapa yang membayar gasnya.
- **Gerbang.** Tes fork: fee mengalir swap → hook → buyback → `execute` membeli AETH dan membakarnya. Invariant: total terbakar ≤ total dibeli.

### Kredit

- **Syarat.** `VAULT_ASSET` = stablecoin mainnet dengan oracle di hub. Setiap token kolateral punya oracle fresh di hub (kolateral saham hanya setelah stock pools dibuka). Keeper likuidasi berjalan sebelum pinjaman pertama.
- **Parameter risiko.** `maxLtv`, `liquidationThreshold`, `liquidationBonus`, `minDebt`, rate model, dan `setCaps`. Mulai dengan cap kecil, naikkan bertahap.
- **Buka.** `vault.setCaps(...)`, `vault.setCreditManager(cm)`, deposit vault awal.
- **Gerbang.** Invariant vault (sudah ada, 4) tetap hijau. Tambah invariant untuk `CreditManager`: utang total tidak melebihi LTV maksimum dikali nilai kolateral kecuali posisi sudah tidak sehat. Tes fork likuidasi dengan harga oracle bergerak.
- **Risiko.** Tertinggi. Likuidasi, rate model, dan ketergantungan oracle.

## 7. Blocker

| Tahap | Blocker eksternal | Pemilik |
|---|---|---|
| Batch A | Alamat stablecoin dan token saham mainnet, penanda tangan Safe, top-up ETH, scope npm | Kamu |
| DLMM/DAMM | Top-up ETH | Kamu |
| Stock pools | Alamat dan verifikasi feed harga mainnet | Kamu, dibantu riset |
| Launchpad | Parameter kurva final | Kamu setelah tinjauan |
| AETH + buyback | Holder dan alokasi AETH, alamat keeper | Kamu |
| Kredit | Stablecoin vault, oracle kolateral, keeper likuidasi, parameter risiko | Kamu |

## 8. Kebijakan biaya

- Sebelum tiap tahap hitung ulang: `gas × harga gas sekarang × harga ETH`. Catat di `PROGRESS.md`.
- Total kumulatif (deploy + pembukaan + cadangan) tidak boleh melewati $8 pada harga yang berlaku. Bila terlampaui, hentikan dan putuskan bersama.
- Cadangan upgrade dipakai hanya untuk perbaikan keamanan.
