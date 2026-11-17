#!/usr/bin/env bash
# Compare la page surveillée à la dernière version connue, puis prévient en cas de changement.
#
# Le dépôt étant public, rien ne doit y révéler le site surveillé :
#   - l'adresse vient d'un secret (masqué dans les logs) ;
#   - la dernière version est stockée chiffrée (state/page.enc, clé = NTFY_TOPIC) ;
#   - les logs n'affichent ni l'adresse ni le contenu de la page.
#
# Tant que la page diffère de la référence, chaque passage renvoie l'alerte. La référence
# ne change que sur action explicite (ACCEPT=1, case « Valider » du workflow) ; le workflow
# committe alors le nouveau state/page.enc (sortie changed=true).
#
# Variables d'environnement :
#   URL            page à surveiller (obligatoire, secret WATCH_URL)
#   NTFY_TOPIC     sujet ntfy (obligatoire), sert aussi de clé de chiffrement
#   NTFY_TOKEN     jeton d'accès d'un compte ntfy.sh (optionnel, recommandé)
#   TELEGRAM_USER  @pseudo Telegram pour l'appel CallMeBot (optionnel)
#   ALERT_TITLE    titre de l'alerte (notification et appel)
#   ALERT_MESSAGE  texte de l'alerte (notification et appel, 256 caractères max pour l'appel)
#   VALIDATE_URL   lien du bouton « Valider » de l'alerte (page du workflow sur GitHub)
#   TEST=1         envoie une notification de test sans rien comparer
#   ACCEPT=1       enregistre la page actuelle comme nouvelle référence
#   HEARTBEAT=0    désactive la notification horaire « Veille active »
set -euo pipefail

: "${URL:?secret WATCH_URL manquant}"
: "${NTFY_TOPIC:?secret NTFY_TOPIC manquant}"
STATE="state/page.enc"
NEW="$(mktemp)"
OLD="$(mktemp)"
trap 'rm -f "$NEW" "$OLD"' EXIT

ALERT_TITLE="${ALERT_TITLE:-Changement détecté}"
ALERT_MESSAGE="${ALERT_MESSAGE:-La page surveillée a changé.}"
HEARTBEAT_PREFIX="Veille"   # sert à retrouver le message horaire déjà envoyé

# Avec un jeton de compte ntfy.sh, les limites d'envoi vers les téléphones sont propres
# au compte et non à l'adresse IP (partagée par tous les runners GitHub).
NTFY_AUTH=()
[ -n "${NTFY_TOKEN:-}" ] && NTFY_AUTH=(-H "Authorization: Bearer $NTFY_TOKEN")

encrypt() { openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass env:NTFY_TOPIC -in "$1" -out "$2"; }
decrypt() { openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass env:NTFY_TOPIC -in "$1" -out "$2" 2>/dev/null; }

# ntfy_publish '<json>' : publie un message ntfy (le sujet est ajouté ici)
ntfy_publish() {
  curl -fsS --retry 3 -X POST "https://ntfy.sh/" "${NTFY_AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "$(jq -c --arg t "$NTFY_TOPIC" '. + {topic:$t}' <<< "$1")" >/dev/null \
    && echo "ntfy : envoyé" || echo "ntfy : échec" >&2
}

# notify titre message [détails] : les détails ne vont que dans la notification ntfy,
# l'appel Telegram lit seulement le titre et le message.
notify() {
  local title="$1" message="$2" details="${3:-}" nl=$'\n'
  ntfy_publish "$(jq -n --arg ti "$title" --arg m "$message${details:+$nl$nl$details}" --arg site "$URL" \
                       --arg valid "${VALIDATE_URL:-}" \
    '{title:$ti, message:$m, priority:5, tags:["ticket","rotating_light"], click:$site,
      actions:([{action:"view", label:"Réserver", url:$site}]
               + (if $valid != "" then [{action:"view", label:"Valider (stop alerte)", url:$valid}] else [] end))}')"
  if [ -n "${TELEGRAM_USER:-}" ]; then
    # CallMeBot répond 200 même en cas d'erreur : on lit sa réponse.
    # Le service gratuit refuse souvent l'appel (« FLOOD ») : on réessaie toutes les 45 s.
    local reply attempt
    for attempt in 1 2 3 4 5 6; do
      reply="$(curl -sS --retry 2 --max-time 90 -G "https://api.callmebot.com/start.php" \
        --data-urlencode "user=$TELEGRAM_USER" \
        --data-urlencode "text=$title. $message" \
        --data-urlencode "lang=fr-FR-Standard-A" \
        --data-urlencode "rpt=2" 2>&1 || true)"
      # On n'affiche que le verdict, pas le texte lu (il passerait dans les logs publics)
      reply="$(echo "$reply" | sed -E 's/<[^>]*>/ /g' | grep -oiE 'Autorization OK|Error:[^.]*|Script ended[^.]*|not authori[a-z]*' | head -3 | tr '\n' ' ')"
      echo "appel Telegram, essai $attempt : $reply"
      echo "$reply" | grep -qiE 'FLOOD|Too many' || break
      sleep 45
    done
  else
    echo "appel Telegram : secret TELEGRAM_USER vide, appel ignoré"
  fi
}

# heartbeat titre message : notification discrète, une seule par heure.
# GitHub saute parfois des passages : plutôt que « le passage de :03 », on envoie au premier
# passage de l'heure qui ne trouve pas déjà un message « Veille… » sur ntfy depuis le début de l'heure.
heartbeat() {
  [ "${HEARTBEAT:-1}" = "1" ] || return 0
  local since already
  since=$(( $(date +%s) / 3600 * 3600 ))
  already="$(curl -fsS --max-time 30 "${NTFY_AUTH[@]}" "https://ntfy.sh/$NTFY_TOPIC/json?poll=1&since=$since" \
    | jq -s --arg p "$HEARTBEAT_PREFIX" 'map(select(.event == "message" and ((.title // "") | startswith($p)))) | length' \
    || echo 0)"
  if [ "$already" != "0" ]; then
    echo "Message horaire déjà envoyé cette heure-ci."
    return 0
  fi
  ntfy_publish "$(jq -n --arg ti "$HEARTBEAT_PREFIX $1" --arg m "$2" --arg site "$URL" \
    '{title:$ti, message:$m, priority:3, tags:["white_check_mark"], click:$site}')"
}

# Texte visible de la page (sans balises), pour montrer ce qui a changé dans la notification
page_text() { sed -E 's/<(script|style)[^>]*>.*<\/(script|style)>//g; s/<[^>]*>/ /g' "$1" | tr -s ' \t' ' ' | sed -E 's/^ +| +$//g' | grep -v '^$' || true; }

NOW_LOCAL="$(TZ=Europe/Paris date +%H:%M)"

if [ "${TEST:-0}" = "1" ]; then
  notify "[TEST] $ALERT_TITLE" "$ALERT_MESSAGE" "Ceci est un test : aucun changement n'a été détecté."
  exit 0
fi

# 3 essais. Une erreur réseau n'est pas un changement : on passe sans échouer,
# sinon GitHub enverrait un e-mail d'échec toutes les 10 min pendant une panne du site.
if ! curl -fsSL --retry 3 --retry-delay 10 --max-time 60 -A "Mozilla/5.0 (veille-contenu)" "$URL" -o "$NEW" 2>/dev/null \
   || [ ! -s "$NEW" ]; then
  if [ "${ACCEPT:-0}" = "1" ]; then
    echo "::error::Page injoignable : impossible de l'enregistrer comme référence. Réessaie plus tard."
    exit 1
  fi
  echo "::warning::Page injoignable ou vide, passage ignoré."
  heartbeat "⚠️ site injoignable" "$URL ne répond pas (vérification de $NOW_LOCAL, heure de Paris). La veille continue."
  exit 0
fi

# Normalisation : fins de ligne et espaces en fin de ligne
normalize() { tr -d '\r' < "$1" | sed -E 's/[[:space:]]+$//'; }

if [ "${ACCEPT:-0}" = "1" ]; then
  echo "Validation : la page actuelle devient la référence."
  mkdir -p state && encrypt "$NEW" "$STATE"
  echo "changed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  ntfy_publish "$(jq -n --arg ti "$HEARTBEAT_PREFIX : nouvelle référence enregistrée" --arg site "$URL" \
    --arg m "La version actuelle de $URL est validée. L'alerte s'arrête jusqu'au prochain changement." \
    '{title:$ti, message:$m, priority:3, tags:["white_check_mark"], click:$site}')"
  exit 0
fi

if [ ! -f "$STATE" ] || ! decrypt "$STATE" "$OLD"; then
  # Premier passage, ou clé changée : on enregistre la page comme référence, sans alerte
  echo "Pas de référence lisible : la page actuelle devient la référence."
  mkdir -p state && encrypt "$NEW" "$STATE"
  echo "changed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

if diff -q <(normalize "$OLD") <(normalize "$NEW") >/dev/null; then
  echo "Aucun changement."
  heartbeat "active : aucun changement" "Rien de nouveau sur $URL (vérification de $NOW_LOCAL, heure de Paris)."
  exit 0
fi

# La référence n'est pas mise à jour : l'alerte repart à chaque passage jusqu'à la validation.
echo "Changement détecté (en attente de validation)."
CHANGES="$(diff <(page_text "$OLD") <(page_text "$NEW") | grep '^>' | sed 's/^> /+ /' | head -5 | cut -c1-200 || true)"

notify "$ALERT_TITLE" "$ALERT_MESSAGE" "${CHANGES:+Nouveau texte :$'\n'$CHANGES$'\n\n'}Cette alerte revient à chaque vérification tant que tu n'as pas validé la nouvelle version."
