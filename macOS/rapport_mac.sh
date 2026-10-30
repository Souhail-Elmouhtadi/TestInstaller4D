#!/bin/bash
# Build the Markdown + HTML report of ONE run from results/<ver>_<build>_<LANG>.tsv (one column per language).
# Usage: bash rapport_mac.sh <results dir> <ver_build> <product> <version> <build> <platform> [run id]
# Only the files of the run (#RUN header, argument 7 or $RUN_ID) are merged: a language tested by an older run never
# appears as a result of this one. Without run id: the run of the most recent file.
# Every status has its own label (only ok is green); a row absent from a file is shown as "—" (no result), never as a success.
DIR="$1"; SAFE="$2"; PRODUCT="$3"; VERSION="$4"; BUILD="$5"; PLATFORM="$6"; RUN="${7:-${RUN_ID:-}}"
MD="$DIR/rapport_${SAFE}.md"; HTML="$DIR/rapport_${SAFE}.html"
run_of() { awk -F'\t' '$1=="#RUN"{print $2; exit}' "$1"; }
if [ -z "$RUN" ]; then
  newest=""
  for l in EN FR DE CS JA; do
    f="$DIR/${SAFE}_$l.tsv"; [ -f "$f" ] || continue
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
  done
  [ -n "$newest" ] && RUN="$(run_of "$newest")"
fi
FILES=(); ABOUT=""; IGNORED=""
for l in EN FR DE CS JA; do
  f="$DIR/${SAFE}_$l.tsv"; [ -f "$f" ] || continue
  if [ "$(run_of "$f")" != "$RUN" ]; then IGNORED="$IGNORED $l"; continue; fi
  FILES+=("$f")
  [ -f "$DIR/${SAFE}_${l}_about.png" ] && ABOUT="$ABOUT$l=${SAFE}_${l}_about.png;"   # About box screenshot (automatic check)
done
[ ${#FILES[@]} -gt 0 ] || { echo "no result of run '$RUN' for $SAFE in $DIR" >&2; exit 1; }
DATE="$(date '+%Y-%m-%d %H:%M')"
DMGWIN=""; [ -f "$DIR/${SAFE}_dmg_window.png" ] && DMGWIN="${SAFE}_dmg_window.png" # window of the disk image (before installation)

gen() { # md|html
  awk -F'\t' -v mode="$1" -v abouts="$ABOUT" -v prod="$PRODUCT" -v ver="$VERSION" -v bld="$BUILD" -v plat="$PLATFORM" \
      -v date="$DATE" -v run="$RUN" -v dmgwin="$DMGWIN" -v ignored="$IGNORED" '
  function esc(s) { if (mode=="html") { gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s) } else gsub(/\|/,"\\|",s); return s }
  function first(s) { sub(/\\n.*/, "", s); return s }
  function label(st) {
    if (st=="ok") return "✅ OK"
    if (st=="ko") return "❌ Échec"
    if (st=="manual") return "⚠️ À vérifier"
    if (st=="action") return "✋ Action requise"
    if (st=="undetermined") return "❔ Indéterminé"
    if (st=="notrun") return "⏭️ Non exécuté"
    if (st=="na") return "N/A"
    if (st=="") return "—"
    return "❔ " st
  }
  function cls(st) { return (st ~ /^(ok|ko|manual|action|undetermined|notrun|na)$/) ? st : (st=="" ? "none" : "undetermined") }
  function cell(st, d,  t) {
    t=label(st); if (st=="ko" && first(d)!="") t=t " — " first(d)
    if (mode=="html") return "<span class=\"st " cls(st) "\">" esc(t) "</span>"
    return esc(t)
  }
  BEGIN {
    na=split(abouts, AB, ";"); for (i=1;i<=na;i++) if (split(AB[i], kv, "=")==2) about[kv[1]]=kv[2]
    n=split("Operating system version used|The download|DMG window (before installation)|Installation of 4D|The installer Editor|Version number|\"Components\" folder|No more plugins provided|Download last 4D I.C.|Load of components|Check if FAT application|Execution of application (with Internet)|Notarization ticket (stapling)|Execution of application (without Internet)|Execution in '\''Rosetta'\'' mode|ReadMe", A, "|")
    for (j=1;j<=n;j++) known[A[j]]=1
  }
  FNR==1 { F[++nf]=FILENAME; L=FILENAME; sub(/.*_/, "", L); sub(/\.tsv$/, "", L); lang[FILENAME]=L }
  $1=="#HASH" { h[$2]=$3; next }
  /^#/ { k=substr($1,2); hv[FILENAME SUBSEP k]=$2; if (k=="LANG" && $2!="") lang[FILENAME]=$2; next }
  NF>=2 {
    st[FILENAME SUBSEP $1]=$2; det[FILENAME SUBSEP $1]=$3; dt[FILENAME SUBSEP $1]=$4; pth[FILENAME SUBSEP $1]=$5
    if (!($1 in known)) { known[$1]=1; A[++n]=$1 } # row of another version of the engine: shown, never dropped
  }
  END {
    H=(mode=="html")
    for (i=1;i<=nf;i++) for (j=1;j<=n;j++) { s=st[F[i] SUBSEP A[j]]; c[cls(s)]++ }
    os=hv[F[1] SUBSEP "OS"]
    split("ok ko manual action undetermined notrun na none", ORD, " ")
    syn=""; for (o=1;o<=8;o++) if (c[ORD[o]]>0) syn=syn (syn==""?"":" · ") label(ORD[o]=="none"?"":ORD[o]) " : " c[ORD[o]]
    legend="✅ OK · ❌ Échec · ⚠️ À vérifier (contrôle manuel) · ✋ Action requise · ❔ Indéterminé (preuve insuffisante) · ⏭️ Non exécuté · N/A non applicable · — aucun résultat"
    if (H) {
      print "<!DOCTYPE html><html lang=\"fr\"><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light dark\"><title>Test Installer 4D - " esc(prod " " ver " " bld) "</title>"
      print "<style>:root{--bg:#f7f8fc;--fg:#1c1d26;--card:#fff;--line:#d9dce8;--head:linear-gradient(120deg,#4f46e5,#9333ea 55%,#ec4899)}"
      print "@media (prefers-color-scheme:dark){:root{--bg:#14151c;--fg:#e9eaf2;--card:#1e2030;--line:#34374a}}"
      print "body{font-family:-apple-system,Helvetica,Arial;margin:0;background:var(--bg);color:var(--fg)}header{background:var(--head);color:#fff;padding:22px 28px}header h1{margin:0 0 6px}main{padding:20px 28px}"
      print "table{border-collapse:collapse;background:var(--card)}td,th{border:1px solid var(--line);padding:6px 10px;vertical-align:top}th{background:#312e81;color:#fff}td.a{font-weight:600}"
      print ".st{display:inline-block;padding:2px 8px;border-radius:10px;font-weight:600}.ok{background:#d1fae5;color:#065f46}.ko{background:#fee2e2;color:#991b1b}.manual{background:#fef3c7;color:#92400e}"
      print ".action{background:#ffedd5;color:#9a3412}.undetermined{background:#ede9fe;color:#5b21b6}.notrun,.none{background:#e5e7eb;color:#374151}.na{background:#e0f2fe;color:#075985}"
      print "details{margin:4px 0}pre{white-space:pre-wrap;background:var(--card);border:1px solid var(--line);padding:8px}small,.meta{opacity:.8}</style></head><body>"
      print "<header><h1>Test Installer 4D – rapport macOS</h1>" esc(prod) " " esc(ver) " build " esc(bld) " · " esc(plat) "</header><main><ul>"
      print "<li><b>Produit</b> : " esc(prod) "</li><li><b>Version</b> : " esc(ver) "</li><li><b>Build</b> : " esc(bld) "</li><li><b>Plateforme</b> : " esc(plat) "</li><li><b>OS</b> : " esc(os) "</li>"
      print "<li><b>Exécution</b> : <code>" esc(run) "</code> · rapport généré le " date "</li>"
      for (k in h) print "<li><code>" esc(k) "</code> SHA-256 <code>" h[k] "</code></li>"
      if (ignored!="") print "<li><b>Ignorés</b> (autre exécution) :" esc(ignored) "</li>"
      print "<li><b>Synthèse</b> : " esc(syn) "</li></ul><p class=meta>" esc(legend) "</p>"
      print "<table><tr><th>Actions</th>"; for (i=1;i<=nf;i++) print "<th>" esc(lang[F[i]]) "</th>"; print "</tr>"
      for (j=1;j<=n;j++) { printf "<tr><td class=a>%s</td>", esc(A[j]); for (i=1;i<=nf;i++) { k=F[i] SUBSEP A[j]; printf "<td>%s</td>", cell(st[k], det[k]) }; print "</tr>" }
      print "</table>"
      if (dmgwin!="") print "<h2>Fenêtre de l'\''image disque (avant installation)</h2><p><img src=\"" dmgwin "\" alt=\"Fenêtre du DMG\" style=\"max-width:620px;border:1px solid #ccc\"></p>"
      print "<h2>Détails</h2>"
      for (i=1;i<=nf;i++) { f=F[i]; l=lang[f]
        print "<h3>" esc(l) "</h3><ul class=meta><li>Date : " esc(hv[f SUBSEP "DATE"]) "</li><li>Produit : " esc(hv[f SUBSEP "PRODUCT"]) "</li><li>Image disque : " esc(hv[f SUBSEP "DMG"]) "</li><li>Application testée : " esc(hv[f SUBSEP "INSTALLED"]) "</li></ul><p><small>" esc(hv[f SUBSEP "LOCALE"]) "</small></p>"
        if (l in about) print "<p><img src=\"" about[l] "\" alt=\"About " esc(l) "\" style=\"max-width:520px;border:1px solid #ccc\"></p>"
        for (j=1;j<=n;j++) { k=f SUBSEP A[j]; if (k in st) { d=esc(det[k]); gsub(/\\n/,"\n",d)
          print "<details" (st[k]!="ok" && st[k]!="na" ? " open" : "") "><summary>" cell(st[k],"") " " esc(A[j]) " <small>" esc(dt[k]) (pth[k]!="" ? " · " esc(pth[k]) : "") "</small></summary><pre>" d "</pre></details>" } } }
      print "</main></body></html>"
    } else {
      print "# Test Installer 4D - rapport macOS"; print ""
      print "- **Produit** : " prod; print "- **Version** : " ver; print "- **Build** : " bld; print "- **Plateforme** : " plat; print "- **OS** : " os
      print "- **Exécution** : `" run "` · rapport généré le " date
      for (k in h) print "- `" k "` SHA-256 `" h[k] "`"
      if (ignored!="") print "- **Ignorés** (autre exécution) :" ignored
      print "- **Synthèse** : " syn; print ""; print "_" legend "_"
      print ""; s="| Actions |"; t="| --- |"; for (i=1;i<=nf;i++) { s=s " " lang[F[i]] " |"; t=t " --- |" }; print s; print t
      for (j=1;j<=n;j++) { s="| " esc(A[j]) " |"; for (i=1;i<=nf;i++) { k=F[i] SUBSEP A[j]; s=s " " cell(st[k], det[k]) " |" }; print s }
      if (dmgwin!="") { print ""; print "## Fenêtre de l'\''image disque (avant installation)"; print ""; print "![Fenêtre du DMG](" dmgwin ")" }
      print ""; print "## Détails"
      for (i=1;i<=nf;i++) { f=F[i]; l=lang[f]; print ""; print "### " l; print ""
        print "- Date : " hv[f SUBSEP "DATE"]; print "- Produit : " hv[f SUBSEP "PRODUCT"]; print "- Image disque : " hv[f SUBSEP "DMG"]; print "- Application testée : " hv[f SUBSEP "INSTALLED"]
        print ""; print "_" hv[f SUBSEP "LOCALE"] "_"
        if (l in about) { print ""; print "![About " l "](" about[l] ")" }
        for (j=1;j<=n;j++) { k=f SUBSEP A[j]; if (k in st) { print ""; print "**" A[j] "** : " cell(st[k],"") " — " dt[k] (pth[k]!="" ? " — `" pth[k] "`" : "")
          d=det[k]; gsub(/\\n/,"\n    ",d); print ""; print "    " d } } }
    }
  }' "${FILES[@]}"
}
gen md > "$MD"
gen html > "$HTML"
echo "$HTML"
