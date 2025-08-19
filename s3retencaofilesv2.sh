#!/bin/bash
set -euo pipefail

# ===== CONFIG =====
DATALOG="/tm1/GFIN/datalog"
BUCKET="lucashlx-devops-use1"
PREFIX="logs"              # em s3://$BUCKET/$PREFIX
AWS="/usr/bin/aws"
LOG_FILE="/var/log/s3uploadretenca.log"
# ==================

# Garante pasta de log e limpa o arquivo no início
mkdir -p "$(dirname "$LOG_FILE")"
> "$LOG_FILE"

log() {
  echo "$(date '+%F %T') - $*" | tee -a "$LOG_FILE"
}

# ===== Função de sincronização =====
sync_logs() {
  log "==== INICIANDO SYNC DE LOGS PARA S3 ===="
  log "Origem: $DATALOG"
  log "Destino: s3://$BUCKET/$PREFIX"

  local include_args=(
    --exclude "*"
    --include "tm1s??*.log"
    --include "tm1processerror*.log"
    --include "tm1audit.log"
    --include "tm1server.log"
  )

  if "$AWS" s3 sync "$DATALOG" "s3://$BUCKET/$PREFIX" \
       --exact-timestamps \
       "${include_args[@]}"; then
    log "SYNC CONCLUÍDO COM SUCESSO."
  else
    log "ERRO durante sync."
    return 1
  fi
}

# ===== Função de retenção =====
retencao_local() {
  local removed=0 kept=0

  find "$DATALOG" -type f \
    \( -name 'tm1s20??*.log' -o -name 'tm1processerror*.log' \) \
    -mtime +7 -print0 |
  while IFS= read -r -d '' f; do
      local rel key local_md5 s3_md5
      rel="${f#"$DATALOG"/}"
      key="$rel"
      [[ -n "$PREFIX" ]] && key="$PREFIX/$rel"

      local_md5="$(md5sum -- "$f" | awk '{print $1}')"
      s3_md5="$("$AWS" s3api head-object \
                   --bucket "$BUCKET" --key "$key" \
                   --query ETag --output text 2>/dev/null | tr -d '"')"

      if [[ -z "$s3_md5" ]]; then
        log "MANTER: $rel (não existe no S3)"
        kept=$((kept+1))
        continue
      fi

      if [[ "$local_md5" == "$s3_md5" ]]; then
        if rm -f -- "$f"; then
          log "REMOVIDO: $rel (idade >7d e idêntico no S3)"
          removed=$((removed+1))
        else
          log "ERRO ao remover: $rel"
          kept=$((kept+1))
        fi
      else
        log "MANTER: $rel (MD5 diferente: local=$local_md5 / s3=$s3_md5)"
        kept=$((kept+1))
      fi
  done

  log "Resumo retenção: removidos=$removed, mantidos=$kept"
}

# ===== MAIN =====
main() {
  log "==== EXECUÇÃO INICIADA ===="
  if sync_logs; then
    retencao_local
  else
    log "Sync falhou, retenção não será aplicada."
  fi
  log "==== EXECUÇÃO FINALIZADA ===="
}

main "$@"
