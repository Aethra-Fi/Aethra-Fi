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

## B6 · Password database Supabase — `OPEN`

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

## B7 · Akses Vercel ke organisasi GitHub `Aethra-Fi` — `OPEN`

Project Vercel `aethra-fi` sudah dibuat (root `apps/web`, build via turbo, env vars testnet/mainnet terpasang), tapi Vercel tidak bisa melihat repo `Aethra-Fi/Aethra-Fi`.
Buka https://github.com/apps/vercel/installations/new → pilih organisasi **Aethra-Fi** → akses ke repo **Aethra-Fi** (atau All repositories) → Install/Save.
Setelah itu bilang "B7 selesai": saya hubungkan Git, set production branch `mainnet`, dan pasang alias `aethra-fi-testnet.vercel.app` ke branch `testnet`.

