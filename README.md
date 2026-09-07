<p align="center">
  <img src="logo.jpg" alt="prawner" width="600">
</p>

# prawner

`prawner` e' un piccolo tool a riga di comando (`wp-site.sh`) per gestire piu'
siti WordPress su un singolo VPS Linux con stack **nginx + PHP-FPM + MySQL +
WP-CLI + certbot**. Automatizza il provisioning, l'emissione dei certificati
TLS e la rimozione sicura (con backup) dei siti, seguendo sempre le stesse
convenzioni cosi' da avere un parco siti coerente e facile da ispezionare.

## Cosa fa

- **`list`** — tabella riassuntiva di tutti i siti configurati in nginx:
  dominio, docroot, owner, se il vhost e' abilitato, giorni alla scadenza del
  certificato TLS. Segnala anche i docroot senza un vhost corrispondente.
- **`create <dominio>`** — crea da zero un sito nuovo:
  utente di sistema dedicato, database MySQL, download e installazione di
  WordPress via WP-CLI, permessi di filesystem corretti, vhost nginx con
  hardening di base, verifica preventiva del DNS.
- **`cert <dominio>`** — richiede il certificato TLS con certbot (plugin
  nginx), verifica che il DNS punti al server prima di procedere, e allinea
  `home`/`siteurl` di WordPress all'URL https.
- **`remove <dominio>`** — rimuove un sito in modo guidato: esegue prima un
  backup completo (dump del database, archivio dei file, vhost, credenziali)
  in `/var/backups/wp-site`, poi chiede conferma esplicita scrivendo il nome
  del dominio, e solo a quel punto smonta vhost, database, certificato e file.

## Convenzioni

| Cosa      | Percorso / valore                                      |
|-----------|---------------------------------------------------------|
| Docroot   | `/var/www/<dominio>/wordpress/`                          |
| Vhost     | `/etc/nginx/sites-available/<slug>` (senza estensione)   |
| Enable    | symlink in `/etc/nginx/sites-enabled/`                   |
| PHP-FPM   | `unix:/run/php/php8.1-fpm.sock` (pool `www-data`)        |
| TLS       | `certbot --nginx`, riscrive il vhost aggiungendo `:443`  |
| Credenziali | salvate in `/root/wp-sites/<dominio>.txt` (permessi 600) |
| Backup    | `/var/backups/wp-site/<dominio>-<timestamp>/`            |

## Requisiti

Il tool presuppone un VPS gia' configurato con:

- Linux con `bash`, eseguito **come root** (o via `sudo`)
- `nginx`
- PHP-FPM in ascolto su un socket unix (default `php8.1-fpm`)
- MySQL/MariaDB raggiungibile con il client `mysql` (credenziali di root gia'
  disponibili, es. via `~/.my.cnf` o socket auth)
- [`wp-cli`](https://wp-cli.org/) installato e nel `PATH`
- [`certbot`](https://certbot.eff.org/) con il plugin nginx
  (`apt install certbot python3-certbot-nginx`)
- `openssl`, `curl`, `getent`, gli strumenti di base coreutils

Il DNS del dominio deve gia' puntare all'IP pubblico del VPS prima di lanciare
`create` o `cert`: entrambi i comandi verificano la risoluzione e avvisano (o
si bloccano) se non corrisponde.

## Installazione

```bash
git clone https://github.com/<tuo-utente>/prawner.git
cd prawner
sudo ./install.sh
```

Questo copia `bin/wp-site.sh` in `/usr/local/bin/wp-site.sh` e segnala eventuali
dipendenze mancanti. Per disinstallare:

```bash
sudo ./uninstall.sh
```

Per usarlo senza installarlo, e' sufficiente lanciarlo dal repo:

```bash
sudo ./bin/wp-site.sh list
```

## Uso

```bash
wp-site.sh list

wp-site.sh create example.com --admin-email admin@example.com
wp-site.sh create example.com --owner example_com --no-www --admin-email admin@example.com

wp-site.sh cert example.com
wp-site.sh cert example.com --no-www

wp-site.sh remove example.com
```

### Opzioni di `create`

| Opzione           | Descrizione                                              |
|-------------------|-----------------------------------------------------------|
| `--owner <utente>`| Utente di sistema proprietario dei file (default `www-data`, creato se non esiste) |
| `--no-www`        | Non include `www.<dominio>` nel vhost / nel certificato    |
| `--admin-email <mail>` | Email amministratore WordPress (obbligatoria, oppure via `ADMIN_EMAIL`) |

### Variabili d'ambiente

Tutte le convenzioni sono sovrascrivibili per adattarsi a setup diversi:

| Variabile           | Default                                  |
|---------------------|-------------------------------------------|
| `NGINX_AVAIL`        | `/etc/nginx/sites-available`             |
| `NGINX_ENABLED`      | `/etc/nginx/sites-enabled`               |
| `WWW_ROOT`           | `/var/www`                               |
| `PHP_SOCK`           | `/run/php/php8.1-fpm.sock`               |
| `BACKUP_ROOT`        | `/var/backups/wp-site`                   |
| `WP_CLI_CACHE_ROOT`  | `/var/cache/wp-cli`                      |
| `DEFAULT_OWNER`      | `www-data`                               |
| `ADMIN_EMAIL`        | *(vuoto)* — email admin di default per `create`/`cert` |

## Sicurezza

Il vhost generato da `create` include gia':

- blocco dell'esecuzione PHP dentro `wp-content/uploads/`
- deny su `wp-config.php`, `xmlrpc.php`, file dotfile e `readme.html`/`license.txt`
- `DISALLOW_FILE_EDIT` e aggiornamenti minori automatici in `wp-config.php`
- rimozione dei plugin/contenuti di default (`hello`, `akismet`, post di esempio)
- password di database e admin generate casualmente e salvate solo in
  `/root/wp-sites/<dominio>.txt` (mai nella docroot)

Lo script richiede sempre l'esecuzione come root: viene manipolato
`/etc/nginx`, creato/rimosso database MySQL e gestiti utenti di sistema, quindi
va eseguito solo su VPS di cui si ha pieno controllo.

## Licenza

[MIT](LICENSE)
