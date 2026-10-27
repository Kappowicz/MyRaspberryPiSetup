Copy backup-all.sh and backup.conf.example to ~/malinka-backups on the Mac.
Rename the example to backup.conf, set HOST and DRIVE, and chmod 600 backup.conf.
Keep the existing .archive-passphrase; store another copy in a password manager.
Run bash ~/malinka-backups/backup-all.sh deliberately: database services briefly stop.

The script checks the remote success marker and manifest, then downloads,
encrypts, decrypts for verification, and copies to the mounted Drive directory.
Partial files are never selected as completed backups. The existing policy keeps
one completed generation, so it cannot undo older mistakes. Local checksum
verification of a Drive file does not confirm cloud synchronization finished.
