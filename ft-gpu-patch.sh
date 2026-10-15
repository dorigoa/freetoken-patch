#!/usr/bin/env bash
# ft-gpu-patch.sh — workaround FreeToken su sistemi con GPU di architetture diverse
#
# Problema: con `ft serve --gpu <UUID>` FlashInfer decide la PDL (Programmatic
# Dependent Launch) sulla GPU scelta (es. RTX 5060 Ti, sm_120) ma il compilatore
# CuTe genera codice per l'architettura di un'altra GPU (es. RTX 4060 Ti, sm_89):
# ptxas rifiuta le istruzioni `griddepcontrol` e il server crasha.
#
# Soluzione: sostituisce <venv>/bin/ft con un wrapper Python che trasforma
# `--gpu <UUID>[,<UUID>...]` in CUDA_VISIBLE_DEVICES (togliendo --gpu dagli
# argomenti) e poi esegue, nello stesso PID, l'ft originale spostato in
# <venv>/bin/.ft-orig/ft. Se --gpu riceve indici invece di UUID, non tocca nulla.
#
# Uso:   ft-gpu-patch.sh [apply|revert|status] [VENV]
#        VENV di default: $FT_VENV, altrimenti /nvme/freetoken/venv
# Da rieseguire con `apply` dopo ogni installazione/aggiornamento di freetoken.
#
# Variabili utili per il wrapper installato:
#   FT_GPU_PATCH_DRYRUN=1   stampa variabile e comando finali senza eseguire
#   FT_GPU_PATCH_DISABLE=1  passa gli argomenti invariati (per confronti)

set -euo pipefail

MARKER="FT_GPU_PATCH_WRAPPER v1"
ACTION="${1:-apply}"
VENV="${2:-${FT_VENV:-/nvme/freetoken/venv}}"
BIN="$VENV/bin"
FT="$BIN/ft"
ORIG_DIR="$BIN/.ft-orig"
ORIG="$ORIG_DIR/ft"
PY="$BIN/python"
TMP=""

die()  { echo "[ft-gpu-patch] ERRORE: $*" >&2; exit 1; }
info() { echo "[ft-gpu-patch] $*"; }
cleanup() { [ -n "$TMP" ] && rm -f "$TMP"; return 0; }
trap cleanup EXIT

is_wrapper() { [ -f "$FT" ] && grep -q "$MARKER" "$FT"; }

write_wrapper() {
  local dest="$1"
  printf '#!%s\n' "$PY" > "$dest"
  cat >> "$dest" <<'PYEOF'
# FT_GPU_PATCH_WRAPPER v1 -- generato da ft-gpu-patch.sh, non modificare.
# Converte `--gpu <UUID>[,<UUID>...]` in CUDA_VISIBLE_DEVICES e lancia l'ft originale.
import os
import shlex
import sys

ORIG = os.path.join(os.path.dirname(os.path.realpath(__file__)), ".ft-orig", "ft")
UUID_PREFIXES = ("GPU-", "MIG-")
TAG = "[ft-gpu-patch]"


def rewrite(argv):
    """Ritorna (argomenti senza --gpu, lista UUID).

    Accetta `--gpu A`, `--gpu A B`, `--gpu A,B`, `--gpu=A,B`. Se anche un solo
    valore non e' un UUID (es. un indice numerico) l'opzione resta invariata.
    """
    out, uuids, i = [], [], 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--gpu":
            j = i + 1
            while j < len(argv) and not argv[j].startswith("-"):
                j += 1
            tokens, consumed = argv[i + 1:j], argv[i:j]
            i = j
        elif arg.startswith("--gpu="):
            tokens, consumed = [arg.split("=", 1)[1]], [arg]
            i += 1
        else:
            out.append(arg)
            i += 1
            continue
        vals = [v.strip() for t in tokens for v in t.split(",") if v.strip()]
        if vals and all(v.startswith(UUID_PREFIXES) for v in vals):
            uuids.extend(vals)
        else:
            out.extend(consumed)
    return out, uuids


def main():
    if not os.path.isfile(ORIG):
        sys.stderr.write(
            f"{TAG} ft originale non trovato: {ORIG}\n"
            f"{TAG} riesegui 'ft-gpu-patch.sh apply' oppure reinstalla freetoken\n"
        )
        return 127

    args = sys.argv[1:]
    if os.environ.get("FT_GPU_PATCH_DISABLE") != "1":
        args, uuids = rewrite(args)
        if uuids:
            prev = os.environ.get("CUDA_VISIBLE_DEVICES")
            os.environ["CUDA_VISIBLE_DEVICES"] = ",".join(uuids)
            note = f" (sostituisce '{prev}')" if prev not in (None, "") else ""
            sys.stderr.write(
                f"{TAG} CUDA_VISIBLE_DEVICES={os.environ['CUDA_VISIBLE_DEVICES']}"
                f"{note}; --gpu rimosso dagli argomenti\n"
            )

    cmd = [sys.executable, ORIG, *args]
    if os.environ.get("FT_GPU_PATCH_DRYRUN") == "1":
        print("CUDA_VISIBLE_DEVICES=" + os.environ.get("CUDA_VISIBLE_DEVICES", "<non impostata>"))
        print("exec: " + shlex.join(cmd))
        return 0

    sys.stdout.flush()
    sys.stderr.flush()
    try:
        os.execv(sys.executable, cmd)  # stesso PID: l'app desktop continua a gestirlo
    except OSError as exc:
        sys.stderr.write(f"{TAG} exec fallita: {exc}\n")
        return 126


if __name__ == "__main__":
    sys.exit(main())
PYEOF
}

do_apply() {
  [ -x "$PY" ] || die "interprete non trovato: $PY"
  [ -f "$FT" ] || die "entrypoint non trovato: $FT (freetoken e' installato in $VENV?)"

  if is_wrapper; then
    [ -f "$ORIG" ] || die "wrapper presente ma manca $ORIG: reinstalla freetoken e riesegui apply"
    info "patch gia' applicata, nulla da fare"
    return 0
  fi

  grep -qa python "$FT" \
    || die "$FT non sembra un entrypoint Python: annullato per sicurezza"

  mkdir -p "$ORIG_DIR"
  TMP="$(mktemp "$BIN/.ft.patch.XXXXXX")"
  write_wrapper "$TMP"
  "$PY" - "$TMP" <<'EOF' || die "il wrapper generato non e' Python valido"
import ast, sys
with open(sys.argv[1], encoding="utf-8") as f:
    ast.parse(f.read(), sys.argv[1])
EOF
  chmod 755 "$TMP"

  # Stesso filesystem: entrambe le mv sono rename atomici.
  mv -f "$FT" "$ORIG"
  if ! mv -f "$TMP" "$FT"; then
    mv -f "$ORIG" "$FT"
    die "installazione del wrapper fallita, ripristinato l'originale"
  fi
  TMP=""
  info "patch applicata: $FT e' ora il wrapper, originale in $ORIG"
}

do_revert() {
  if ! is_wrapper; then
    info "patch non presente, nulla da ripristinare"
    return 0
  fi
  [ -f "$ORIG" ] || die "manca $ORIG: reinstalla freetoken per ripristinare ft"
  mv -f "$ORIG" "$FT"
  rmdir "$ORIG_DIR" 2>/dev/null || true
  info "ripristinato l'ft originale"
}

do_status() {
  if [ ! -e "$FT" ]; then
    info "stato: $FT non esiste"
  elif is_wrapper; then
    if [ -f "$ORIG" ]; then
      info "stato: patch APPLICATA (originale in $ORIG)"
    else
      info "stato: patch ROTTA, wrapper senza originale: reinstalla freetoken e riesegui apply"
    fi
  else
    info "stato: patch NON applicata"
    [ -f "$ORIG" ] && info "  (in $ORIG c'e' un originale vecchio: apply lo sovrascrivera')"
  fi
  return 0
}

case "$ACTION" in
  apply)  do_apply ;;
  revert) do_revert ;;
  status) do_status ;;
  -h|--help|help) sed -n '2,22p' "$0" ;;
  *) die "azione sconosciuta '$ACTION' (usa apply|revert|status)" ;;
esac
