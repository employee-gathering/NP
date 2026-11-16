# CHAOTIC IMPOSTOR HUNT — Simplified Flow

Implementation target: `employee-gathering/NP`, branch `feature/impostor-hunt` (keep the existing PR in draft; do not merge to `main` before UAT sign-off).

## What changed

- Participant username is the complete `TIM` code from `PEMBAGIAN TIM.xlsx` (for example `B2-T01-M01`); password is the participant's NID.
- Each participant has an individual login, while all members of the parent team (for example `B2-T01`) share the same six-color progress and one final submission.
- The 18 master player QR PNGs from `CIH_QR_Player_Bersama.zip` are displayed on the Admin page and shared by both batches. Old per-batch player QR rows are deactivated. Existing ride QR rows are retained and remain batch-specific.
- Player QR scanning returns the ride assigned to that player's slot for the participant's batch/team. Scanning the correct ride QR adds the letter immediately; no staff verification step is used.
- After six letters are collected, the team can submit once. A voucher is generated for each active team member after submission whether the submitted answer is right or wrong, as required by the event rule.
- A voucher can be redeemed once by an account listed in `public.admin_users`.
- App-specific assignments in `public.app_user_roles` are cleared; administrative access is based on `public.admin_users` only.

## Files

- `web/hunt.html` — participant TIM + NID login, QR scan, team progress, final submit, and personal voucher display.
- `web/hunt-admin.html` — Admin-only batch start and the 18 exact master player QR images.
- `web/team-admin.html` — Admin-only team roster viewer with exact TIM codes.
- `web/food-voucher.html` — participant voucher retrieval fallback.
- `web/food-voucher-admin.html` — Admin-only voucher scanner, redemption, and summary.
- `web/staff-verify.html` and `web/user-role-admin.html` — retired notice pages.
- `db/202611160001_cih_simplified_flow.sql` — database migration; contains QR token hashes but no NID roster.
- `db/PRIVATE_import_TIM_NID_assignments.sql` — private import generated from `PEMBAGIAN TIM.xlsx`; contains NID values and password hashes inputs. Do not commit this file to a public repository.
- `CIH_QR_Player_Bersama.zip` — original QR master archive.

## Apply order

1. Take a Supabase database backup.
2. Run `db/202611160001_cih_simplified_flow.sql` in Supabase SQL Editor as the database owner. The migration preserves existing progress, submissions, and voucher rows. It retires old player QR records, installs the master player QR hashes, keeps existing ride QR records, backfills team-to-player pairings, and replaces old role checks with the Admin allow-list.
3. Run `db/PRIVATE_import_TIM_NID_assignments.sql` in Supabase SQL Editor. This validates 443 workbook rows against active attendees and existing teams before it updates batch/team membership and participant login accounts. It aborts on mismatches, duplicate NIDs, an existing successful submission, or existing vouchers.
4. Deploy the `web/` files to the `feature/impostor-hunt` branch / GitHub Pages target. Keep the private import SQL out of GitHub.
5. UAT both batches: one login each, shared player QR scan, existing ride QR scan, six letters, one submission, voucher generation for all members, and Admin redemption including duplicate-redemption rejection.

## Data and safety notes

- The import is private because it contains NID values. NIDs are stored as bcrypt hashes in `ih_participant_accounts`; the existing attendee table continues to contain its current NID field.
- The import uses the workbook's 443 entries as the source of truth for participant team/batch assignment. It does not delete attendees.
- No UAT progress is reset by either SQL script. In particular, do not reset B2-T01 until the remaining UAT has finished and the user explicitly requests the cleanup.
- Database changes are not applied automatically from this package; the two SQL files must be run in Supabase.