# Changelog

Tutte le modifiche rilevanti a questo progetto sono documentate qui.
Il formato segue [Keep a Changelog](https://keepachangelog.com/it/1.1.0/).

## [Non rilasciato]

### Aggiunto
- `wp-update.sh`: aggiornamento automatico di core, plugin e temi per tutti i
  siti trovati in `$WWW_ROOT`, con backup pre-update, smoke test HTTP e
  rollback automatico in caso di fallimento.
- `cron.d/wp-update`: template per l'esecuzione giornaliera automatica via
  `/etc/cron.d/wp-update` (con `flock` anti-sovrapposizione).
- `install.sh --with-cron` / `uninstall.sh --with-cron`: installano/rimuovono
  anche il cron di `wp-update.sh` insieme ai comandi.

## [1.0.0] - 2026-09-07

### Aggiunto
- Comando `wp-site.sh list`: elenca i siti WordPress configurati su nginx (dominio, docroot, owner, stato enable, scadenza TLS) e segnala docroot orfani.
- Comando `wp-site.sh create`: provisioning completo di un nuovo sito (utente di sistema, database MySQL, download e installazione WordPress via WP-CLI, permessi, vhost nginx con hardening) con verifica DNS preventiva.
- Comando `wp-site.sh cert`: richiesta/rinnovo certificato TLS via certbot con verifica DNS e allineamento automatico di `home`/`siteurl` in WordPress.
- Comando `wp-site.sh remove`: rimozione guidata e confermata di un sito, con backup completo (database + file + vhost) prima di procedere.
- Script `install.sh` / `uninstall.sh` per installare/rimuovere il comando su un VPS.
