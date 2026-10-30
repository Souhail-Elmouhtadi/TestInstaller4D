#!/bin/bash
# Installe « Test Installer 4D » dans /Applications. La quarantaine n'est jamais retirée : copiée depuis une image
# téléchargée, l'app (signée localement, non notarisée par Apple) est vérifiée par Gatekeeper au premier lancement.
# Si macOS la bloque : Réglages Système > Confidentialité et sécurité > « Ouvrir quand même » (une seule fois).
# Une signature Developer ID avec notarisation supprime cette étape.
# Dans le Terminal :  bash "/Volumes/Test Installer 4D/install.sh"
# Alias sur le Bureau seul :  bash install.sh --desktop-alias [app]
SRC="$(cd "$(dirname "$0")" && pwd)/Test Installer 4D.app"
DST="/Applications/Test Installer 4D.app"

# Alias Finder « Test Installer 4D » sur le Bureau (fichier de signet macOS, sans Apple Event au Finder) : il affiche
# l'icône de l'app. Un alias existant est remplacé ; un autre élément du même nom n'est jamais touché.
# 0 = créé, 1 = app ou Bureau introuvable, 2 = autre élément du même nom, 3 = échec de création.
desktop_alias() {
  local app="$1" link="$HOME/Desktop/Test Installer 4D" r
  [ -d "$app" ] && [ -d "$HOME/Desktop" ] || return 1
  if [ -e "$link" ] || [ -L "$link" ]; then
    r="$(alias_tool check "$link")"
    [ "$r" = ALIAS ] || { echo "Bureau : « Test Installer 4D » existe déjà et n'est pas un alias : laissé tel quel."; return 2; }
    rm -f "$link" || return 3
  fi
  r="$(alias_tool make "$app" "$link")"
  [ "$r" = OK ] || { echo "Bureau : alias non créé ($r)."; return 3; }
  echo "Alias sur le Bureau : $link"
}
alias_tool() {
  osascript -l JavaScript - "$@" <<'JXA' 2>&1
ObjC.import('Foundation');
function run(argv) {
  if (argv[0] === 'check') {
    const v = Ref();
    $.NSURL.fileURLWithPath(argv[1]).getResourceValueForKeyError(v, $.NSURLIsAliasFileKey, $());
    return (v[0] && v[0].boolValue) ? 'ALIAS' : 'OTHER';
  }
  const target = $.NSURL.fileURLWithPath(argv[1]), link = $.NSURL.fileURLWithPath(argv[2]);
  const data = target.bookmarkDataWithOptionsIncludingResourceValuesForKeysRelativeToURLError(1 << 10, $(), $(), $());
  if (!data || data.isNil()) return 'ERROR bookmark';
  return $.NSURL.writeBookmarkDataToURLOptionsError(data, link, 0, $()) ? 'OK' : 'ERROR write';
}
JXA
}

if [ "${1:-}" = --desktop-alias ]; then desktop_alias "${2:-$DST}"; exit $?; fi
[ -d "$SRC" ] || { echo "Test Installer 4D.app introuvable à côté de ce script."; exit 1; }
osascript -e 'if application id "com.4d.qa.testinstaller4d" is running then tell application id "com.4d.qa.testinstaller4d" to quit' >/dev/null 2>&1
sleep 1
rm -rf "$DST" && ditto "$SRC" "$DST" || { echo "Échec de l'installation dans /Applications."; exit 1; }
echo "Installé : $DST"
desktop_alias "$DST"
open "$DST"
if xattr -p com.apple.quarantine "$DST" >/dev/null 2>&1; then
  echo "Premier lancement : macOS vérifie l'app (Gatekeeper). Si elle est bloquée (« Apple n'a pas pu vérifier… »),"
  echo "ouvrez Réglages Système > Confidentialité et sécurité, cliquez sur « Ouvrir quand même » et confirmez."
fi
