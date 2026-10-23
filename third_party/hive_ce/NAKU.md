# NAKU storage safety patch

Based on Hive CE 2.19.3, retained under the upstream BSD-3-Clause license.
The binary database format, type IDs and public APIs are unchanged.

Two VM backend files differ from upstream:

- Acquire the box lock before creating/recovering the database or touching
  compaction files, and transfer the same locked handle to the backend.
- Do not truncate lock metadata before acquiring the lock, and do not unlink
  the lock file on close or failed initialization. Read lock metadata through
  the held handle: POSIX closes on another descriptor can release process locks. OS file locks are released
  by closing their handles; the persistent inode prevents a different process
  from locking a replacement inode while an owner is still using the original.

The app additionally holds a session lock, disables destructive crash recovery,
retains binary snapshots and maintains an independent download catalog.

Regressions: `flutter test test/download_storage_recovery_test.dart`.
Separate OS processes verify contention, an owner without the session lock,
unchanged database bytes, corruption and unsupported schema preservation.
