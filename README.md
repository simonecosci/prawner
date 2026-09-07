<p align="center">
  <img src="logo.jpg" alt="prawner" width="600">
</p>

# prawner

`prawner` is a small set of command line tools to manage several WordPress
sites on a single Linux VPS with an **nginx + PHP-FPM + MySQL + WP-CLI +
certbot** stack:

- **`wp-site.sh`** — provisioning, TLS certificates and safe removal (with a
  backup) of sites, always following the same conventions so that you end up
  with a coherent set of sites that is easy to inspect.
- **`wp-update.sh`** — automatic daily updates of core, plugins and themes on
  every site, with a backup and an automatic rollback if something breaks.

## wp-site.sh — site provisioning

- **`list`** — summary table of every site configured in nginx: domain,
  docroot, owner, whether the vhost is enabled, days left before the TLS
  certificate expires. It also reports docroots without a matching vhost.
- **`create <domain>`** — creates a new site from scratch:
  dedicated system user, MySQL database, WordPress download and install via
  WP-CLI, correct filesystem permissions, nginx vhost with basic hardening,
  upfront DNS check.
- **`cert <domain>`** — requests the TLS certificate with certbot (nginx
  plugin), verifies that DNS points to the server before proceeding, and
  aligns WordPress `home`/`siteurl` with the https URL.
- **`remove <domain>`** — removes a site in a guided way: it first takes a
  full backup (database dump, file archive, vhost, credentials) in
  `/var/backups/wp-site`, then asks for explicit confirmation by typing the
  domain name, and only then tears down vhost, database, certificate and files.

## Conventions

| What        | Path / value                                             |
|-------------|----------------------------------------------------------|
| Docroot     | `/var/www/<domain>/wordpress/`                            |
| Vhost       | `/etc/nginx/sites-available/<slug>` (no extension)        |
| Enable      | symlink in `/etc/nginx/sites-enabled/`                    |
| PHP-FPM     | `unix:/run/php/php8.1-fpm.sock` (pool `www-data`)         |
| TLS         | `certbot --nginx`, rewrites the vhost adding `:443`       |
| Credentials | saved in `/root/wp-sites/<domain>.txt` (mode 600)         |
| Backup      | `/var/backups/wp-site/<domain>-<timestamp>/`              |

## Requirements

The tool assumes a VPS that is already set up with:

- Linux with `bash`, run **as root** (or via `sudo`)
- `nginx`
- PHP-FPM listening on a unix socket (default `php8.1-fpm`)
- MySQL/MariaDB reachable with the `mysql` client (root credentials already
  available, e.g. via `~/.my.cnf` or socket auth)
- [`wp-cli`](https://wp-cli.org/) installed and in the `PATH`
- [`certbot`](https://certbot.eff.org/) with the nginx plugin
  (`apt install certbot python3-certbot-nginx`)
- `openssl`, `curl`, `getent`, the basic coreutils tools

The domain DNS must already point to the public IP of the VPS before running
`create` or `cert`: both commands check the resolution and warn (or stop) if
it does not match.

## Installation

```bash
git clone https://github.com/simonecosci/prawner.git
cd prawner
sudo ./install.sh
```

This copies `bin/wp-site.sh` and `bin/wp-update.sh` into `/usr/local/bin/` and
reports any missing dependencies. To install the daily `wp-update.sh` cron job
at the same time:

```bash
sudo ./install.sh --with-cron
```

To uninstall (add `--with-cron` to remove the cron job as well):

```bash
sudo ./uninstall.sh [--with-cron]
```

To use the commands without installing them, just run them from the repo:

```bash
sudo ./bin/wp-site.sh list
sudo ./bin/wp-update.sh --dry-run
```

## Usage — wp-site.sh

```bash
wp-site.sh list

wp-site.sh create example.com --admin-email admin@example.com
wp-site.sh create example.com --owner example_com --no-www --admin-email admin@example.com

wp-site.sh cert example.com
wp-site.sh cert example.com --no-www

wp-site.sh remove example.com
```

### `create` options

| Option                 | Description                                              |
|------------------------|----------------------------------------------------------|
| `--owner <user>`       | System user owning the files (default `www-data`, created if missing) |
| `--no-www`             | Does not include `www.<domain>` in the vhost / certificate |
| `--admin-email <mail>` | WordPress administrator email (required, or via `ADMIN_EMAIL`) |

### Environment variables

Every convention can be overridden to fit different setups:

| Variable            | Default                                   |
|---------------------|-------------------------------------------|
| `NGINX_AVAIL`        | `/etc/nginx/sites-available`             |
| `NGINX_ENABLED`      | `/etc/nginx/sites-enabled`               |
| `WWW_ROOT`           | `/var/www`                               |
| `PHP_SOCK`           | `/run/php/php8.1-fpm.sock`               |
| `BACKUP_ROOT`        | `/var/backups/wp-site`                   |
| `WP_CLI_CACHE_ROOT`  | `/var/cache/wp-cli`                      |
| `DEFAULT_OWNER`      | `www-data`                               |
| `WP_LOCALE`          | `it_IT` — locale of the WordPress installed by `create` |
| `ADMIN_EMAIL`        | *(empty)* — default admin email for `create`/`cert` |

## wp-update.sh — automatic updates

`wp-update.sh` scans `$WWW_ROOT` looking for every real WordPress installation
(every `wp-config.php` found, not just `<domain>/wordpress`) and for each one:

1. takes a backup (DB dump + tar of `wp-content/{plugins,themes,mu-plugins}`,
   `uploads` excluded) in `$BACKUP_ROOT/<site>/<timestamp>/`;
2. updates core → plugins → themes → DB schema;
3. runs an HTTP smoke test (home page + `wp-login.php`, checking the response
   for PHP/DB errors);
4. if the smoke test fails, performs an **automatic rollback** from the backup
   just taken (core, `wp-content`, database) and retries the smoke test.

The "canary" sites (paths containing `test`, e.g. `wordpress-test`) are updated
first, so that a problem shows up there before production sites are touched.

```bash
wp-update.sh                   # update everything
wp-update.sh --dry-run         # only show what would be updated
wp-update.sh --site example.com   # a single site (partial match on the path)
wp-update.sh --no-core         # plugins and themes only
wp-update.sh --skip-smoke      # skip the smoke test and the rollback
```

The exit code is non-zero if at least one site had problems — handy for cron
monitoring.

### Environment variables

| Variable            | Default             |
|---------------------|---------------------|
| `WWW_ROOT`           | `/var/www`          |
| `BACKUP_ROOT`        | `/var/backups/wp`   |
| `LOG_DIR`            | `/var/log/wp-update` |
| `KEEP_BACKUPS`       | `3` (backup sets kept per site) |
| `MIN_FREE_MB`        | `1024` (minimum space required on `BACKUP_ROOT`) |
| `CURL_TIMEOUT`       | `30` (seconds, for the smoke test) |
| `WP_CLI_CACHE_ROOT`  | `/var/cache/wp-cli`  |

### Daily cron

The easiest way is to install it together with the commands:

```bash
sudo ./install.sh --with-cron
```

Alternatively, by hand:

```bash
sudo cp cron.d/wp-update /etc/cron.d/wp-update
sudo chmod 644 /etc/cron.d/wp-update
sudo chown root:root /etc/cron.d/wp-update
```

The [`cron.d/wp-update`](cron.d/wp-update) file runs `wp-update.sh` every day
at 03:30 as root, with `flock` to avoid overlapping runs if a previous update
is still in progress:

```cron
30 3 * * * root flock -n /run/wp-update.lock /usr/local/bin/wp-update.sh >> /var/log/wp-update/cron.log 2>&1
```

Logs:

- `/var/log/wp-update/cron.log` — output of the last cron run
- `/var/log/wp-update/<timestamp>.log` — detailed log of each single run

## Security

The vhost generated by `create` already includes:

- PHP execution blocked inside `wp-content/uploads/`
- deny on `wp-config.php`, `xmlrpc.php`, dotfiles and `readme.html`/`license.txt`
- `DISALLOW_FILE_EDIT` and automatic minor updates in `wp-config.php`
- removal of the default plugins/content (`hello`, `akismet`, sample post)
- randomly generated database and admin passwords, saved only in
  `/root/wp-sites/<domain>.txt` (never in the docroot)

The script always requires being run as root: it manipulates `/etc/nginx`,
creates/drops MySQL databases and manages system users, so it should only be
run on VPSes you fully control.

## License

[MIT](LICENSE)
