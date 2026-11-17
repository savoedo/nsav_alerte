# Veille

Toutes les 10 minutes, GitHub Actions télécharge une page web et la compare à la dernière
version connue. En cas de changement :

1. une notification ntfy prioritaire part sur le téléphone, avec le nouveau texte de la page ;
2. CallMeBot passe un appel Telegram qui lit le message ;
3. la nouvelle version est enregistrée.

Toutes les heures, une notification discrète confirme que la veille tourne (ou que le site
ne répond pas). Une erreur réseau n'est pas comptée comme un changement.

Le dépôt est public mais ne révèle pas la page surveillée : son adresse est un secret,
la version enregistrée est chiffrée (`state/page.enc`) et les logs n'affichent ni l'une ni l'autre.

## Secrets à définir

*Settings → Secrets and variables → Actions → New repository secret* :

| Secret | Contenu |
|---|---|
| `WATCH_URL` | adresse de la page à surveiller |
| `NTFY_TOPIC` | sujet ntfy, long et aléatoire ; sert aussi de clé de chiffrement |
| `NTFY_TOKEN` | jeton d'un compte ntfy.sh (optionnel, rend la livraison plus fiable) |
| `TELEGRAM_USER` | `@pseudo` Telegram pour l'appel (optionnel) |

Sur le téléphone : appli ntfy abonnée au même sujet, et `/start` envoyé à `@CallMeBot_txtbot`
dans Telegram pour autoriser l'appel.

## Utilisation

- **Test** : *Actions → Veille → Run workflow*, cocher « Envoyer une notification de test ».
- **Texte de l'alerte** : `ALERT_TITLE` et `ALERT_MESSAGE` dans `.github/workflows/veille.yml`.
- **Changer de page ou de sujet ntfy** : modifier le secret ; au passage suivant, la page
  actuelle devient la nouvelle référence, sans alerte.

## Bon à savoir

- GitHub peut retarder ou sauter des passages planifiés ; un service comme cron-job.org peut
  déclencher le workflow (API `workflow_dispatch`) pour plus de régularité.
- Sur un dépôt public, GitHub désactive les tâches planifiées après 60 jours sans commit.
  Le workflow fait un petit commit tous les 45 jours pour l'éviter.
