---
id: CLAUDE
aliases: []
tags: []
---

# PROMPT — ATM Quanta Pools → Aethra Fi (Amati, Tiru, Modifikasi UI)

Kamu adalah lead engineer proyek eksperimen DeFi **Aethra Fi** (slug: `aethra-fi`), liquidity layer di Robinhood Chain hasil ATM dari Quanta Pools. Jalankan seluruh pengembangan **end-to-end tanpa berhenti per fase**: setup → localhost → testnet → **dry run mainnet**. Folder tempat Claude Code dijalankan adalah root proyek (`ROOT`). Semua perintah bash wajib diberi komentar direktori, contoh: `# Jalankan di: ROOT/packages/contracts`.

---

## 1. Data tetap (tidak ada yang perlu ditanyakan)

- **Alamat wallet deployer: `0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C`**. Pakai alamat ini di semua script, config, dan dokumentasi (`DEPLOYER_ADDRESS`). Jangan tanyakan lagi.
- **Referensi UI:** https://www.quantus.com/ (screenshot tambahan ada di folder ui-reference).

Langsung mulai bekerja setelah saya mengetik "Mulai".

---

## 2. Tujuan: ATM

1. **Amati** https://quantapools.tech/ dan https://quantapools.tech/app memakai REA lewat CLI (`npx -y rea-agents@latest --help` untuk melihat perintahnya; repo: https://github.com/morluto/rea). Amati halaman, alur pengguna, panggilan network, dan antarmuka kontrak (ABI dari https://robinhoodchain.blockscout.com). Tulis temuan dengan kata-kata sendiri di `docs/research/notes.md`.
2. **Tiru** semua fitur secara fungsional dengan kode sendiri:
   swap, smart router multi-venue, create pool, deposit liquidity, DAMM, DLMM, limit order, positions (LP NFT + locker), pools discovery + filter (trending, most traded, highest volume, fresh), dynamic fee hook, oracle guard hook, launchpad markets (setara Pons), stock token pools, kredit/lending (LP sebagai kolateral), buyback & burn, analytics, event feed, halaman contracts, halaman developers (SDK/API).
3. **Modifikasi UI** hanya mengambil **gaya dan vibe** dari website referensi UI (bukan strukturnya). Sumbernya: https://www.quantus.com/ dan screenshot di `ROOT/docs/ui-reference/` (lihat screenshot dengan Read, buka link dengan browser jika perlu). Struktur halaman, alur, dan fitur tetap mengikuti Aethra Fi; website referensi boleh jauh berbeda dari produk ini.
    - Ekstrak gayanya ke `docs/ui-style/style-guide.md`: palet warna (sampel dari screenshot), tipografi, skala spacing, radius, bayangan/glow, gaya border, kepadatan informasi, gaya tombol/kartu/input, ikon, dan motion/animasi.
    - **Primary color Aethra Fi: `#86F61F`** (hijau lime). Warna ini tetap, tidak diambil dari referensi. Jadikan `--primary` / `primary` di design tokens, dan turunkan skala 50–950, state hover/active/focus, serta warna teks di atasnya dengan kontras yang terbaca (WCAG AA) di kedua tema. Warna netral, aksen sekunder, dan nuansa lainnya diambil dari gaya referensi dan dipadukan agar harmonis dengan `#86F61F`.
    - **Dua tema: gelap (default) dan terang.** Tema gelap aktif untuk pengunjung baru, bukan mengikuti `prefers-color-scheme`. Sediakan toggle tema di navbar, simpan pilihan pengguna (localStorage, dibungkus try/catch), dan cegah kedipan tema saat halaman dimuat. Pakai `next-themes` dengan `defaultTheme="dark"`, `enableSystem={false}`, dan `attribute="class"` (Tailwind `darkMode: "class"`).
    - Semua design tokens didefinisikan untuk **kedua tema** sebagai CSS variables (background, surface, border, teks, muted, primary, aksen, status sukses/error/peringatan, bayangan/glow). Jangan pakai warna hardcode di komponen; selalu pakai token.
    - Ambil gaya dan vibe referensi untuk tema gelap lebih dulu. Untuk tema terang, turunkan versi yang sepadan dengan DNA visual yang sama dan kontras yang cukup (WCAG AA). Jika screenshot referensi hanya ada satu tema, tema satunya dirancang sendiri.
    - Grafik, RainbowKit, dan shadcn/ui juga harus mengikuti tema yang aktif.
    - Verifikasi kedua tema di setiap halaman, termasuk screenshot Playwright untuk dark dan light pada halaman utama (landing, swap, pools, positions).
    - Terapkan sebagai design tokens (Tailwind config + CSS variables) lalu pakai di semua halaman Aethra Fi.
    - Font: identifikasi lalu pakai padanan open-source (Google Fonts/Fontsource); jangan memakai font berlisensi tanpa lisensi.
    - Logo, ilustrasi, foto, dan copywriting dibuat orisinal untuk **Aethra Fi**.

Batasan: jangan menyalin source code, bundle, aset, logo, atau teks Quanta Pools maupun website referensi UI. Jangan memakai nama "Quanta" atau menyiratkan afiliasi dengan Quanta Pools/Robinhood.

---

## 3. Chain (sudah terverifikasi, verifikasi ulang dengan `cast chain-id` saat setup)

|           | Testnet                                      | Mainnet                                 |
| --------- | -------------------------------------------- | --------------------------------------- |
| Nama      | Robinhood Chain Testnet                      | Robinhood Chain                         |
| Chain ID  | 46630                                        | 4663                                    |
| RPC       | https://rpc.testnet.chain.robinhood.com      | https://rpc.mainnet.chain.robinhood.com |
| Explorer  | https://explorer.testnet.chain.robinhood.com | https://robinhoodchain.blockscout.com   |
| Faucet    | https://faucet.testnet.chain.robinhood.com   | —                                       |
| Gas token | ETH                                          | ETH                                     |

- Cek apakah Uniswap v4 (PoolManager, PositionManager) dan launchpad tersedia di testnet. Jika tidak, deploy versi uji di localhost/testnet atau buat mock, lalu catat di `docs/BLOCKERS.md`. Di mainnet, Uniswap v4 PoolManager ada di `0x8366a39CC670B4001A1121B8F6A443A643e40951` (verifikasi di explorer).
- Stock token / oracle yang belum tersedia di testnet: pakai mock oracle.

---

## 4. Setup otomatis (kerjakan sendiri di awal sesi pertama)

1. Tulis `ROOT/.claude/settings.json`:
    ```json
    {
        "attribution": { "commit": "", "pr": "" },
        "permissions": {
            "allow": [
                "Bash(pnpm:*)",
                "Bash(npm:*)",
                "Bash(npx:*)",
                "Bash(node:*)",
                "Bash(forge:*)",
                "Bash(cast:*)",
                "Bash(anvil:*)",
                "Bash(supabase:*)",
                "Bash(vercel:*)",
                "Bash(git:*)",
                "Bash(gh:*)",
                "Bash(docker:*)",
                "Bash(curl:*)",
                "Bash(mkdir:*)",
                "Bash(chmod:*)"
            ]
        }
    }
    ```
    Jika izin belum aktif di sesi ini, minta saya restart Claude Code sekali, lalu lanjutkan.
2. Cek dan pasang tools yang belum ada: Node ≥ 22.19, pnpm, Foundry (`foundryup`), Supabase CLI, Vercel CLI, GitHub CLI, Docker (harus berjalan), Chrome.
3. Cek login: `gh auth status`, `supabase projects list`, `vercel whoami`, `git config user.name/email`. Jika belum login, jalankan perintah login-nya dan minta saya mengonfirmasi di browser.
4. **Repo GitHub sudah ada: https://github.com/Aethra-Fi/Aethra-Fi.git** (organisasi `Aethra-Fi`). Jangan membuat repo baru.
    - Cek akses dan isinya: `gh repo view Aethra-Fi/Aethra-Fi` dan `git ls-remote https://github.com/Aethra-Fi/Aethra-Fi.git`.
    - Folder proyek sudah berstatus git (`git init -b main`). Hubungkan: `git remote add origin https://github.com/Aethra-Fi/Aethra-Fi.git`.
    - Jika repo remote masih kosong: push `main` sebagai branch pertama. Jika sudah berisi commit: `git fetch origin` lalu gabungkan ke `main` lokal tanpa menimpa isinya (jangan force-push); jika bentrok atau tidak jelas, catat di `docs/BLOCKERS.md`.
    - Jika `gh` tidak punya akses push ke organisasi `Aethra-Fi`, catat di `docs/BLOCKERS.md` agar saya memberi akses, lalu lanjutkan pekerjaan lokal.
    - Buat branch `testnet` dan `mainnet` di repo ini. Jangan mengubah visibilitas repo.
5. Pasang git hooks (lihat bagian 8) sebelum commit pertama.
6. Cek keystore deployer: `cast wallet list`. Jika `deployer` belum ada, tulis di `docs/BLOCKERS.md`: saya harus menjalankan `cast wallet import deployer --interactive` di terminal saya sendiri.

---

## 5. Stack & environment

- Monorepo pnpm + Turborepo: `apps/web` (Next.js, TypeScript, Tailwind, wagmi/viem, RainbowKit, shadcn/ui), `packages/contracts` (Foundry), `packages/sdk` (ABI + alamat per network), `supabase/` (migrasi, Edge Functions untuk indexer & API).
- Pakai library yang sudah teruji (OpenZeppelin, Uniswap v4 periphery, Solady/PRBMath). Cek lisensi sebelum dipakai.

| Environment | Branch    | Frontend                                     | Database                                 | Chain                                                    |
| ----------- | --------- | -------------------------------------------- | ---------------------------------------- | -------------------------------------------------------- |
| localhost   | `main`    | `pnpm dev`                                   | Supabase lokal (Docker)                  | Anvil fork testnet, chain ID 31337, `--auto-impersonate` |
| testnet     | `testnet` | Vercel → `aethra-fi-testnet.vercel.app`      | Supabase `aethra-fi-testnet`             | Robinhood Chain Testnet                                  |
| mainnet     | `mainnet` | Vercel production (disiapkan, belum dipakai) | Supabase `aethra-fi-mainnet` (disiapkan) | Robinhood Chain — **dry run saja**                       |

- Setiap fitur jalan di localhost dulu, lalu dipromosikan ke testnet lewat PR `main` → `testnet` (`gh pr create` + `gh pr merge`).
- Hubungkan project Vercel ke repo `Aethra-Fi/Aethra-Fi` (Production Branch `mainnet`, Root Directory `apps/web`; branch `testnet` mendapat preview/alias `aethra-fi-testnet.vercel.app`).
- Kamu punya akses penuh ke Supabase dan Vercel: buat project (region `ap-southeast-1`), env vars per branch, domain `.vercel.app`, migrasi, Edge Functions, `pg_cron` untuk indexer. Password database disimpan di `~/.config/aethra-fi/supabase.env` (chmod 600), tidak pernah ditampilkan. Service role key hanya di Supabase secrets. Catat semua resource di `docs/infrastructure.md`.

---

## 6. Wallet deployer (satu-satunya wallet)

- Satu wallet deployer untuk semua deployment kontrak, sekaligus owner dan pemegang hak upgrade. Alamat: `0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C`.
- Simpan di `.env.example` sebagai `DEPLOYER_ADDRESS=0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C` (alamat publik, aman di-commit) dan di `packages/sdk/src/addresses/{network}.json` (field `deployer`).
- Setelah keystore `deployer` ada, verifikasi alamatnya cocok sebelum deploy apa pun: `cast wallet address --account deployer` harus menghasilkan `0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C`. Jika tidak cocok, **berhenti** dan catat di `docs/BLOCKERS.md`; jangan deploy dengan alamat lain.
- Sebelum deploy testnet, cek saldo: `cast balance 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C --rpc-url https://rpc.testnet.chain.robinhood.com`. Jika 0, tulis di `docs/BLOCKERS.md` agar saya mengisinya dari faucet.
- Localhost: impersonate alamat deployer di Anvil (`forge script --unlocked --sender $DEPLOYER_ADDRESS`), tanpa private key.
- Testnet & dry run mainnet: `--account deployer` (Foundry keystore). Private key tidak boleh ada di repo, `.env`, atau log.
- Perintah yang meminta password keystore **saya jalankan sendiri** di terminal saya. Siapkan perintah lengkap (dengan direktori) di `docs/BLOCKERS.md`, gabungkan semua deploy dalam satu script per batch, lalu kerjakan task lain sambil menunggu. Setelah saya selesai, baca hasil broadcast di `packages/contracts/broadcast/` dan perbarui `packages/sdk/src/addresses/testnet.json`.

---

## 7. Kontrak upgradeable & budget

**Proxy (alamat tidak berubah saat update):**

- UUPS (ERC-1967) dengan OpenZeppelin `contracts-upgradeable`; BeaconProxy untuk kontrak yang dibuat berulang dengan logika sama.
- `initialize()` sebagai pengganti constructor, `_disableInitializers()` di constructor implementasi, namespaced storage (ERC-7201).
- Alamat yang dipakai SDK, frontend, dan indexer adalah **alamat proxy**.
- Validasi upgrade dengan OpenZeppelin Foundry Upgrades dan test v1 → v2 di localhost. Script upgrade di `packages/contracts/script/upgrade/`.
- Hook Uniswap v4: proxy hook di-deploy dengan CREATE2 ke alamat hasil mining flag; tentukan semua flag yang mungkin dibutuhkan sejak awal karena flag tidak bisa diubah lewat upgrade.

**Budget deploy mainnet: $6–$7 total** (harga gas dan ETH terkini saat dry run):

- Desain hemat sejak awal: optimizer aktif, BeaconProxy untuk kontrak berulang, pakai ulang kontrak yang sudah ada di chain (Uniswap v4, WETH), tanpa kontrak yang tidak perlu.
- Catat estimasi biaya mainnet di `docs/PROGRESS.md` setiap kali kontrak bertambah.
- Akhir proyek: `forge script ... --rpc-url mainnet` **tanpa `--broadcast`**. Laporkan biaya per kontrak, total ETH dan USD, harga gas dan ETH yang dipakai, dan status di dalam / di luar budget. Jika melebihi $7, optimalkan lalu ulangi; jika masih melebihi, laporkan opsi dan biarkan saya memutuskan. **Jangan broadcast ke mainnet.**

Tidak perlu audit smart contract dan tidak perlu disclaimer di website (proyek eksperimen). Tetap tulis test (unit + fuzz) bersamaan dengan kontraknya.

---

## 8. Git

- Repo: https://github.com/Aethra-Fi/Aethra-Fi.git (remote `origin`). Jangan pernah force-push.
- Semua commit dan PR atas nama saya (identitas git yang sudah ada). Jangan pakai `--author`.
- **Tanpa watermark Claude**: tidak ada `Co-Authored-By: Claude`, `Generated with Claude Code`, `Claude-Session:`, atau emoji 🤖 di commit maupun PR. Claude tidak boleh muncul sebagai contributor di GitHub.
- Hooks di `ROOT/.githooks/`, aktifkan dengan `git config core.hooksPath .githooks`:
    - `commit-msg`: buang baris yang cocok dengan `co-authored-by:.*(claude|anthropic)`, `claude-session:`, `generated with .*claude`.
    - `pre-push`: tolak push jika ada commit dengan atribusi AI atau email `noreply@anthropic.com`; jalankan `pnpm lint`, `pnpm typecheck`, `pnpm test`, `forge test`.
- Tidak memakai GitHub Actions. Deploy frontend lewat integrasi Git Vercel.
- Commit kecil langsung ke `main` (Conventional Commits).

---

## 9. Cara kerja

- Urutan: setup → riset REA → fondasi monorepo & environment → landing + wallet + swap → kontrak inti (hooks, registry, router, positions) → indexer & halaman data → launchpad & stock pools → DAMM/DLMM, limit order, kredit, buyback → modifikasi UI → deploy testnet → dry run mainnet.
- Jangan menunggu konfirmasi di antara langkah. Workstream kontrak, frontend, dan data boleh paralel dengan subagent.
- Keputusan teknis yang ambigu: pilih opsi paling masuk akal, catat satu baris di `docs/PROGRESS.md`, lanjutkan.
- Jika sebuah task gagal 3 kali dengan pendekatan berbeda, catat di `docs/BLOCKERS.md` dan lanjutkan task lain.
- Berhenti hanya untuk hal yang wajib saya lakukan: konfirmasi login di browser, import keystore, ambil dana faucet, menjalankan perintah yang meminta password keystore.
- `docs/PROGRESS.md` (status semua task) dan `docs/BLOCKERS.md` (yang menunggu saya) selalu terkini. Laporkan ke saya hanya saat milestone selesai, ada blocker baru, atau dry run mainnet selesai.

**Sesi berikutnya:** baca `docs/PROGRESS.md` dan `docs/BLOCKERS.md`, cek blocker yang sudah saya selesaikan, lalu lanjutkan dari task terakhir.
