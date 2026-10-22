# BLOCKERS — hal yang menunggu kamu

Status: `OPEN` = masih menunggu, `DONE` = sudah selesai (dicek ulang di awal sesi).

---

## B1 · Login Supabase CLI — `OPEN`

Supabase CLI sudah terpasang (`~/.local/bin/supabase` v2.121.0), tapi belum login. Jalankan:

```bash
# Jalankan di: ROOT
supabase login
```

Perintah ini membuka browser untuk konfirmasi. **Jalankan di terminal biasa di luar Claude Code**: `! supabase login` gagal karena prompt Claude Code bukan TTY (`LoginMissingTokenError`).
Alternatif: buat token di https://supabase.com/dashboard/account/tokens lalu `supabase login --token <token>`, juga di terminal luar (jangan lewat `!`, supaya token tidak masuk log percakapan).
Setelah login, project `aethra-fi-testnet` dan `aethra-fi-mainnet` (region `ap-southeast-1`) akan saya buat sendiri.

## B2 · Import keystore `deployer` — `OPEN`

`cast wallet list` hanya menampilkan `alphamarkets-mainnet` dan `hume-mainnet`. Keystore `deployer` belum ada.
Jalankan di terminal kamu sendiri (private key **jangan** ditempel ke chat):

```bash
# Jalankan di: ROOT
cast wallet import deployer --interactive
# Verifikasi: hasilnya harus 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C
cast wallet address --account deployer
```

## B3 · Dana faucet testnet — `OPEN`

Saldo `0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C` di Robinhood Chain Testnet = **0 ETH**.
Ambil ETH di https://faucet.testnet.chain.robinhood.com ke alamat itu. Cek:

```bash
# Jalankan di: ROOT
cast balance 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C --rpc-url https://rpc.testnet.chain.robinhood.com -e
```

## B4 · Deploy testnet (butuh password keystore) — `BELUM SIAP`

Perintah lengkap akan saya tulis di sini setelah kontrak lolos di localhost.
