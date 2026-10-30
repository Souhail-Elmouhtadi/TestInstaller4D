#!/bin/bash
# Test Installer 4D - start the macOS checklist.
# Double-click in Finder, or run it in Terminal:  bash "Test Installer 4D.command"  [--restore-locale]
# The disk image is always chosen by the user (never a silent choice); the product, version and build must be the
# ones read in the image. The installation (install_4d.sh) is optional and confirmed; an existing installation is
# never replaced without confirmation; macOS asks for an administrator when needed (no password asked nor stored here).
KIT="$(cd "$(dirname "$0")" && pwd)"
cd "$KIT" || exit 1
. "$KIT/version.sh" || exit 1
# No quarantine is ever removed: the kit scripts are always run with bash (bash script.sh is not assessed by
# Gatekeeper) and 4D opens quarantined test projects normally.
chmod +x "$KIT"/*.sh "$KIT"/*.command 2>/dev/null

if [ "$1" = "--restore-locale" ]; then bash "$KIT/qa_mac.sh" --restore-locale; exit $?; fi

ask() { # question default
  local a; printf '%s [%s] : ' "$1" "$2" > /dev/tty; read -r a < /dev/tty; echo "${a:-$2}"; }
pause_exit() { read -r -p "Entrée pour fermer..." _; exit "${1:-1}"; }
choose_dmg() {
  osascript -e 'POSIX path of (choose file with prompt "Choisissez le DMG 4D téléchargé depuis product-download.4d.com")' 2>/dev/null; }
# events of install_4d.sh in plain French (awk keeps the empty fields)
show_events() {
  awk -F'\t' '{
    if ($1=="STEP") print "• " $2
    else if ($1=="PROGRESS") printf "    %3d %%  %s\n", $2, $3
    else if ($1=="INFO") print "    " $2 " : " $3
    else if ($1=="EXISTS") print "  Installation existante : " $2 " (" $3 " build " $4 ")"
    else if ($1=="ERROR") print "  ERREUR [" $2 "] : " $3
    else if ($1=="RESULT") print ($2=="ok" ? "  Installé et vérifié : " $3 : "  Installation non effectuée")
    else print "    " $0
    fflush() }'
}

echo "=============================================="
echo "   Test Installer 4D - macOS"
echo "=============================================="
echo "Téléchargez d'abord le DMG depuis https://product-download.4d.com (connexion à votre compte 4D dans le navigateur)."
echo

[ -f "$KIT/kit.conf" ] && . "$KIT/kit.conf"   # previous answers
PREV_DMG="${DMG:-}"; DMG=""

# ---- DMG: list of the finished downloads (download_4d.sh --scan), chosen by the user ----
while [ -z "$DMG" ]; do
  LIST="$( { bash "$KIT/download_4d.sh" --scan "$KIT"; bash "$KIT/download_4d.sh" --scan "$HOME/Downloads"; } 2>/dev/null \
    | awk -F'\t' '$1=="CANDIDATE" && !seen[$2]++' | sort -t$'\t' -k7,7nr)"
  i=0; DEF=""; PATHS=()
  if [ -n "$LIST" ]; then
    echo "Images disque trouvées (dossier du kit et ~/Downloads) :"
    while IFS= read -r l; do
      p="$(cut -f2 <<< "$l")"; sz="$(cut -f3 <<< "$l")"; state="$(cut -f4 <<< "$l")"; org="$(cut -f5 <<< "$l")"; hosts="$(cut -f6 <<< "$l")"
      case "$org" in official) o="serveur 4D ($hosts)";; other) o="AUTRE ORIGINE ($hosts)";; *) o="origine inconnue";; esac
      if [ "$state" = complete ]; then
        i=$((i+1)); PATHS[$i]="$p"; [ "$p" = "$PREV_DMG" ] && DEF=$i
        printf '  %d) %s  (%s Mo, %s)\n' "$i" "$(basename "$p")" "$((sz/1048576))" "$o"
      else
        case "$state" in empty) why="fichier vide";; invalid) why="fin d'image disque absente";; *) why="téléchargement en cours";; esac
        printf '  -  %s  (%s : non utilisable)\n' "$(basename "$p")" "$why"
      fi
    done <<< "$LIST"
  else
    echo "Aucune image disque trouvée (dossier du kit ou ~/Downloads)."
  fi
  echo "  0) choisir un autre fichier    t) ouvrir la page de téléchargement 4D    r) actualiser la liste    q) quitter"
  a="$(ask "Votre choix" "${DEF}")"
  case "$a" in
    q|Q) exit 0;;
    t|T) open "https://product-download.4d.com/" && echo "Connectez-vous dans le navigateur et téléchargez le DMG, puis tapez r."; continue;;
    r|R|"") continue;;
    0) DMG="$(choose_dmg)"; [ -n "$DMG" ] || DMG="$(ask "Chemin du DMG" "")";;
    *) if [[ "$a" =~ ^[0-9]+$ ]] && [ -n "${PATHS[$a]:-}" ]; then DMG="${PATHS[$a]}"; else echo "Choix invalide : $a"; fi;;
  esac
  [ -z "$DMG" ] || [ -f "$DMG" ] || { echo "DMG introuvable : $DMG"; DMG=""; }
done
echo "DMG choisi : $DMG"

# ---- product / version / build read in the DMG (Info.plist): the build is not in the DMG name ----
echo "Lecture de la version dans le DMG..."
INFO="$(bash "$KIT/dmg_info.sh" "$DMG" 2> "$KIT/.dmg_info_err")"
[ -n "$INFO" ] || { echo "Impossible de lire le DMG : $(cat "$KIT/.dmg_info_err")"; rm -f "$KIT/.dmg_info_err"; pause_exit 1; }
rm -f "$KIT/.dmg_info_err"
echo "Contenu : $(cut -f1-3 <<< "$INFO" | awk -F'\t' '{printf "%s%s %s build %s", (NR>1?" ; ":""), $1, $2, $3}')"
while :; do
  PRODUCT="$(ask "Produit (4D, 4D Server, 4D Volume Desktop)" "${PRODUCT:-4D}")"
  L="$(awk -F'\t' -v p="$PRODUCT" '$1==p' <<< "$INFO" | head -1)"
  [ -n "$L" ] && break
  echo "« $PRODUCT » n'est pas dans ce DMG (produits présents : $(cut -f1 <<< "$INFO" | paste -sd, - | sed 's/,/, /g'))."
done
GV="$(cut -f2 <<< "$L")"; GB="$(cut -f3 <<< "$L")"
echo "DMG : $PRODUCT $GV build $GB (Info.plist)"
while :; do
  VERSION="$(version_normalize "$(ask "Version attendue (ex. 21.2, 21 R2)" "$GV")")"
  BUILD="$(ask "Build attendu" "$GB")"
  version_equal "$VERSION" "$GV" && [ "$BUILD" = "$GB" ] && break
  echo "Le DMG contient $PRODUCT $GV build $GB, pas $VERSION build $BUILD : téléchargez la bonne version (aucune autre version n'est choisie à votre place)."
  [ "$(ask "Réessayer (r) ou quitter (q)" r)" = q ] && exit 1
done
case "$(uname -m)" in arm64) DP="macOS ARM";; *) DP="macOS Intel";; esac
PLATFORM="$(ask "Plateforme (macOS ARM / macOS Intel)" "${PLATFORM:-$DP}")"

CUR="$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ",' | cut -d- -f1 | tr 'a-z' 'A-Z')"
case "$CUR" in EN|FR|DE|CS|JA) ;; *) CUR=EN;; esac
# 4D is started in each language with a per-application language: no macOS change, no log out
LANGS="$(ask "Langue(s) à tester, séparées par des espaces (EN FR DE CS JA)" "$CUR" | tr 'a-z' 'A-Z')"

yn() { case "$(ask "$1 (o/n)" "$2")" in o|O|y|Y) echo 1;; *) echo 0;; esac; }
TEST_CONTROL="$(yn "Test témoin (dossier Components renommé)" o)"
TEST_GITHUB="$(yn "Test des composants depuis GitHub" o)"
mkdir -p "$KIT/ic"
if ls "$KIT"/ic/*.zip >/dev/null 2>&1; then TEST_IC="$(yn "Tester les 4D Internet Commands (zips dans ic/)" o)"
else echo "(Aucun zip 4D Internet Commands dans ic/ : test I.C. ignoré)"; TEST_IC=0; fi
D_NET=n; [ "${NET_AUTO:-0}" = 1 ] && D_NET=o
NET_AUTO="$(yn "Test sans Internet automatique (pare-feu pf : confirmation et mot de passe administrateur au début, sinon coupure manuelle)" "$D_NET")"

q() { printf '%q' "$1"; }
{
  echo "PRODUCT=$(q "$PRODUCT")"; echo "VERSION=$(q "$VERSION")"; echo "BUILD=$(q "$BUILD")"
  echo "PLATFORM=$(q "$PLATFORM")"; echo "DMG=$(q "$DMG")"
  echo "TEST_CONTROL=$TEST_CONTROL"; echo "TEST_GITHUB=$TEST_GITHUB"; echo "TEST_IC=$TEST_IC"; echo "NET_AUTO=$NET_AUTO"
  echo "INSTALL_DEST=$(q "${INSTALL_DEST:-/Applications}")"
} > "$KIT/kit.conf"

# ---- installation (optional, confirmed): the execution tests launch the installed application ----
echo
if [ "$(yn "Installer $PRODUCT $VERSION build $BUILD depuis ce DMG avant les tests" o)" = 1 ]; then
  INSTALL_DEST="$(ask "Dossier de destination" "${INSTALL_DEST:-/Applications}")"
  sed -i '' '/^INSTALL_DEST=/d' "$KIT/kit.conf"; echo "INSTALL_DEST=$(q "$INSTALL_DEST")" >> "$KIT/kit.conf"
  ILOG="$HOME/4DQA_mac/install_log.txt"; mkdir -p "$HOME/4DQA_mac"
  MODE=""
  while :; do
    bash "$KIT/install_4d.sh" --dmg "$DMG" --product "$PRODUCT" --version "$VERSION" --build "$BUILD" \
      --platform "$PLATFORM" --dest "$INSTALL_DEST" $MODE | tee "$ILOG" | show_events
    rc=${PIPESTATUS[0]}
    [ "$rc" = 3 ] || break
    E="$(awk -F'\t' '$1=="EXISTS"' "$ILOG" | head -1)"
    echo "Une installation existe déjà : $(cut -f2 <<< "$E") ($(cut -f3 <<< "$E") build $(cut -f4 <<< "$E"))."
    case "$(ask "r = la remplacer (l'ancienne va dans la Corbeille), u = utiliser l'existante (vérifiée), a = ne pas installer" a)" in
      r|R) MODE=--replace;; u|U) MODE=--adopt;; *) echo "Installation non effectuée : les tests d'exécution seront « Non exécuté »."; break;;
    esac
  done
else
  echo "Installation non demandée : les tests d'exécution utilisent la dernière installation faite par l'outil si elle correspond à ce DMG, sinon « Non exécuté »."
fi

SAFE="$(printf '%s_%s' "$VERSION" "$BUILD" | tr ' /' '__')"
OUT="$KIT/qa_mac_results.tsv"; REP=""
export RUN_ID="$(date +%Y%m%d-%H%M%S)-$$" # one run = all its languages; the report never merges an older run
# automatic offline test: one permission for the whole run; the guard lifts any block when this script ends
export NET_SESSION=1; unset NET_GUARD_NOTE
if [ "$NET_AUTO" = 1 ]; then
  echo; echo "Test sans Internet automatique : confirmation, puis mot de passe administrateur dans la fenêtre de macOS…"
  G="$(bash "$KIT/net_guard.sh" start $$)"; rc=$?
  case "$rc" in
    0) echo "Garde réseau prêt : le trafic sera bloqué (pare-feu pf) pendant chaque test sans Internet, puis rétabli."
       trap 'bash "$KIT/net_guard.sh" quit >/dev/null 2>&1' EXIT;;
    2) export NET_GUARD_NOTE="automatic cut declined at the start of the run"
       echo "Coupure automatique refusée : le test sans Internet vous demandera de couper le réseau vous-même.";;
    *) export NET_GUARD_NOTE="automatic cut unavailable: ${G#ERROR }"
       echo "Coupure automatique indisponible (${G#ERROR }) : coupure manuelle demandée.";;
  esac
fi
for LANG_CODE in $LANGS; do
  echo; echo "Lancement de la checklist ($LANG_CODE)..."; echo
  MARK="$KIT/.run_mark"; touch "$MARK"; sleep 1
  bash "$KIT/qa_mac.sh" "$LANG_CODE"
  if [ -s "$OUT" ] && [ "$OUT" -nt "$MARK" ] && grep -q '^#LANG' "$OUT"; then
    L="$(awk -F'\t' '$1=="#LANG"{print $2}' "$OUT")"
    mkdir -p "$KIT/results"; cp "$OUT" "$KIT/results/${SAFE}_${L}.tsv"
    REP="$(bash "$KIT/rapport_mac.sh" "$KIT/results" "$SAFE" "$PRODUCT" "$VERSION" "$BUILD" "$PLATFORM" "$RUN_ID")"
  else
    echo; echo "Pas de résultat pour $LANG_CODE (voir le journal ci-dessus)."
  fi
  rm -f "$MARK"
done
if [ -n "$REP" ]; then echo; echo "Rapport : $REP"; echo "          ${REP%.html}.md"; open "$REP" 2>/dev/null; fi
echo
read -r -p "Entrée pour fermer..." _
