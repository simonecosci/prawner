<p align="center">
  <img src="logo.jpg" alt="prawner" width="600">
</p>

# prawner

`prawner` e' un piccolo set di tool a riga di comando per gestire piu' siti
WordPress su un singolo VPS Linux con stack **nginx + PHP-FPM + MySQL +
WP-CLI + certbot**:

- **`wp-site.sh`** — provisioning, certificati TLS e rimozione sicura (con
  backup) dei siti, seguendo sempre le stesse convenzioni cosi' da avere un
  parco siti coerente e facile da ispezionare.
- **`wp-update.sh`** — aggiornamento giornaliero automatico di core, plugin e
  temi su tutti i siti, con backup e rollback automatico se qualcosa si rompe.

## wp-site.sh — provisioning dei siti

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
git clone https://github.com/simonecosci/prawner.git
cd prawner
sudo ./install.sh
```

Questo copia `bin/wp-site.sh` e `bin/wp-update.sh` in `/usr/local/bin/` e
segnala eventuali dipendenze mancanti. Per installare anche il cron
giornaliero di `wp-update.sh` in un colpo solo:

```bash
sudo ./install.sh --with-cron
```

Per disinstallare (aggiungi `--with-cron` per rimuovere anche il cron):

```bash
sudo ./uninstall.sh [--with-cron]
```

Per usare i comandi senza installarli, e' sufficiente lanciarli dal repo:

```bash
sudo ./bin/wp-site.sh list
sudo ./bin/wp-update.sh --dry-run
```

## Uso — wp-site.sh

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

## wp-update.sh — aggiornamenti automatici

`wp-update.sh` scandisce `$WWW_ROOT` alla ricerca di ogni installazione
WordPress reale (ogni `wp-config.php` trovato, non solo `<dominio>/wordpress`)
e per ciascuna:

1. fa un backup (dump del DB + tar di `wp-content/{plugins,themes,mu-plugins}`,
   esclusi gli `uploads`) in `$BACKUP_ROOT/<sito>/<timestamp>/`;
2. aggiorna core → plugin → temi → schema del DB;
3. esegue uno smoke test HTTP (home page + `wp-login.php`, controllo di
   errori PHP/DB nella risposta);
4. se lo smoke test fallisce, esegue il **rollback automatico** dal backup
   appena fatto (core, `wp-content`, database) e ritenta lo smoke test.

I siti "canarino" (path contenente `test`, es. `wordpress-test`) vengono
aggiornati per primi, cosi' un problema emerge li' prima di toccare i siti
di produzione.

```bash
wp-update.sh                   # aggiorna tutto
wp-update.sh --dry-run         # mostra solo cosa verrebbe aggiornato
wp-update.sh --site example.com   # un solo sito (match parziale sul path)
wp-update.sh --no-core         # solo plugin e temi
wp-update.sh --skip-smoke      # salta smoke test e rollback
```

L'exit code e' diverso da zero se almeno un sito ha avuto problemi — utile
per il monitoring del cron.

### Variabili d'ambiente

| Variabile           | Default            |
|---------------------|---------------------|
| `WWW_ROOT`           | `/var/www`          |
| `BACKUP_ROOT`        | `/var/backups/wp`   |
| `LOG_DIR`            | `/var/log/wp-update` |
| `KEEP_BACKUPS`       | `3` (set di backup mantenuti per sito) |
| `MIN_FREE_MB`        | `1024` (spazio minimo richiesto su `BACKUP_ROOT`) |
| `CURL_TIMEOUT`       | `30` (secondi, per lo smoke test) |
| `WP_CLI_CACHE_ROOT`  | `/var/cache/wp-cli`  |

### Cron giornaliero

Il modo piu' semplice e' installarlo insieme ai comandi:

```bash
sudo ./install.sh --with-cron
```

In alternativa, a mano:

```bash
sudo cp cron.d/wp-update /etc/cron.d/wp-update
sudo chmod 644 /etc/cron.d/wp-update
sudo chown root:root /etc/cron.d/wp-update
```

Il file [`cron.d/wp-update`](cron.d/wp-update) lancia `wp-update.sh` ogni
giorno alle 03:30 come root, con `flock` per evitare run sovrapposti se
un aggiornamento precedente e' ancora in corso:

```cron
30 3 * * * root flock -n /run/wp-update.lock /usr/local/bin/wp-update.sh >> /var/log/wp-update/cron.log 2>&1
```

Log:

- `/var/log/wp-update/cron.log` — output dell'ultima esecuzione via cron
- `/var/log/wp-update/<timestamp>.log` — log dettagliato di ogni singolo run

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
