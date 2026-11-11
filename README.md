# Employee Gathering — GitHub Pages

Frontend statis untuk mengelola peserta melalui Supabase. Tidak menyertakan data peserta atau kredensial rahasia.

## Deploy
1. Upload `index.html` ke root repository `employee-gathering.github.io`.
2. Repository Settings → Pages → Deploy from a branch → `main` → `/ (root)` → Save.
3. Buka `https://employee-gathering.github.io/`.
4. Masukkan Supabase Project URL dan Publishable Key pada layar konfigurasi.
5. Login menggunakan akun Supabase Auth yang UUID-nya terdaftar di `public.admin_users`.

## Catatan penting
- Frontend menggunakan tabel `public.attendees` dengan kolom `id`, `nid`, `full_name`, `batch`, `vehicle`, `notes`, `active`, serta tabel `public.admin_users` dengan kolom `user_id`.
- Pastikan RLS dan policies membatasi semua operasi peserta hanya untuk admin terdaftar.
- Batas 500 peserta wajib ditegakkan di database dengan constraint/trigger, bukan hanya validasi browser.
- Publishable Key boleh digunakan di browser; jangan pernah memasukkan `sb_secret_` atau `service_role` ke repository.
- File CSV peserta berisi data pribadi; jangan commit ke repository publik.
