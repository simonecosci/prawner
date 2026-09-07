# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `wp-update.sh`: automatic core, plugin and theme updates for every site
  found under `$WWW_ROOT`, with a pre-update backup, an HTTP smoke test and
  automatic rollback on failure.
- `cron.d/wp-update`: template for the automatic daily run via
  `/etc/cron.d/wp-update` (with `flock` to prevent overlapping runs).
- `install.sh --with-cron` / `uninstall.sh --with-cron`: install/remove the
  `wp-update.sh` cron job along with the commands.

## [1.0.0] - 2026-09-07

### Added
- `wp-site.sh list` command: lists the WordPress sites configured in nginx (domain, docroot, owner, enabled state, TLS expiry) and reports orphaned docroots.
- `wp-site.sh create` command: full provisioning of a new site (system user, MySQL database, WordPress download and install via WP-CLI, permissions, hardened nginx vhost) with an upfront DNS check.
- `wp-site.sh cert` command: TLS certificate request/renewal via certbot with a DNS check and automatic alignment of WordPress `home`/`siteurl`.
- `wp-site.sh remove` command: guided, confirmed removal of a site, with a full backup (database + files + vhost) taken before proceeding.
- `install.sh` / `uninstall.sh` scripts to install/remove the command on a VPS.
