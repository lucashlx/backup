#!/bin/bash
set -euo pipefail

########################################
# Configurações
########################################
LOG_FILE="/var/log/s3_upload_retencao.log"
DATALOG="/tm1/GFIN/datalog"
S3_BUCKET="s3://lucashlx-devops-use1/logs"   # mantenha com prefixo s3://
AWS_BIN="/usr/bin/aws"

# DRY-RUN (true/false) — útil para testar sem enviar
DRY_RUN=false

# Aplicar retenção e remoção local (true/false)
REMOVE_AFTER_SYNC=true

# Garante pasta de log e limpa/cria arquivo
mkdir -p "$(dirname "$LOG_FILE")"
> "$LOG_FILE"

# Lista de arquivos enviados com sucesso (para retenção segura)
declare -a ARQUIVOS_ENVIADOS_OK=()

########################################
# Util
########################################
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

########################################
# Sync filtrado para S3
########################################
sync_to_s3() {
  log_message "==== INICIANDO SYNC S3 (filtrado) ===="
  log_message "Origem: $DATALOG"
  log_message "Destino: $S3_BUCKET"

  if [ ! -d "$DATALOG" ]; then
    log_message "ERRO: Diretório de origem não existe: $DATALOG"
    return 1
  fi
  if [[ -z "$S3_BUCKET" || "$S3_BUCKET" != s3://* ]]; then
    log_message "ERRO: S3_BUCKET inválido: $S3_BUCKET"
    return 1
  fi

  # Padrões permitidos
  local patterns=(
    "tm1s20??*.log"
    "tm1auditore.log"
    "tm1processor20??*.log"
    "tm1processerror*.log"
  )

  # Monta include/exclude: exclui tudo, inclui só os padrões
  local sync_output
  sync_output="$(mktemp)"

  local include_args=( --exclude "*" )
  for p in "${patterns[@]}"; do
    include_args+=( --include "$p" )
  done

  # DRY-RUN flag (opcional)
  local maybe_dry=()
  if $DRY_RUN; then
    maybe_dry+=( --dryrun )
    log_message "ATENÇÃO: DRY-RUN ATIVO (não envia nem cria nada no S3)."
  fi

  # Importante: não usar --delete (manter o que já existe no bucket)
  if "$AWS_BIN" s3 sync "$DATALOG" "$S3_BUCKET" \
        --exact-timestamps \
        "${include_args[@]}" \
        "${maybe_dry[@]}" \
        2>&1 \
        | tee "$sync_output" | tee -a "$LOG_FILE"; then
    log_message "AWS S3 Sync executado com sucesso!"

    # Ex.: "upload: datalog/tm1s2077.log to s3://bucket/logs/tm1s2077.log"
    while IFS= read -r linha; do
      [[ "$linha" == upload:* ]] || continue

      # pega caminho local após "upload: " e antes de " to "
      local local_local_path file_basename arquivo_original
      local_local_path="$(echo "$linha" | awk -F' to ' '{print $1}' | sed 's/^upload: //')"
      file_basename="$(basename "$local_local_path")"

      # confirma caminho no DATALOG
      arquivo_original="$(find "$DATALOG" -type f -name "$file_basename" | head -n1 || true)"
      if [[ -n "${arquivo_original:-}" ]]; then
        ARQUIVOS_ENVIADOS_OK+=("$arquivo_original")
        log_message "SUCESSO -> Marcado para retenção segura: $file_basename"
      fi
    done < "$sync_output"

    rm -f "$sync_output"
    return 0
  else
    log_message "ERRO no sync S3!"
    rm -f "$sync_output"
    return 1
  fi
}

########################################
# Retenção local (7 dias)
########################################
aplicar_retencao() {
  log_message "====== APLICANDO RETENÇÃO DE 7 DIAS ======"
  if [ ${#ARQUIVOS_ENVIADOS_OK[@]} -eq 0 ]; then
    log_message "Nenhum arquivo marcado como enviado. Nada a aplicar."
    return 0
  fi

  local removed_count=0
  for arquivo in "${ARQUIVOS_ENVIADOS_OK[@]}"; do
    if [[ -f "$arquivo" ]]; then
      local base
      base="$(basename "$arquivo")"

      # Só aplica a retenção nos padrões corretos
      if [[ "$base" == tm1s20??*.log || "$base" == tm1processerror*.log ]]; then
        # Verifica idade maior que 7 dias
        if [ "$(find "$arquivo" -mtime +7 -print)" ]; then
          if rm -f -- "$arquivo"; then
            removed_count=$((removed_count + 1))
            log_message "REMOVIDO (retenção >7 dias): $base"
          else
            log_message "ERRO ao remover $base"
          fi
        else
          log_message "Mantido (idade <=7 dias): $base"
        fi
      else
        log_message "Ignorado (fora da política): $base"
      fi
    fi
  done

  log_message "Total removido por retenção: $removed_count"
}

########################################
# Main
########################################
main() {
  log_message "==== Iniciando upload filtrado de logs para S3 ===="
  log_message "Padrões incluídos: tm1s20??*.log | tm1auditore.log | tm1processor20??*.log | tm1processerror*.log"
  log_message "Comportamento no S3: manter arquivos existentes (sem --delete)"

  if sync_to_s3; then
    log_message "Upload OK. Enviados: ${#ARQUIVOS_ENVIADOS_OK[@]} arquivo(s)."
    if $REMOVE_AFTER_SYNC && ! $DRY_RUN; then
      aplicar_retencao
    else
      $DRY_RUN && log_message "DRY-RUN: retenção desabilitada."
      ! $REMOVE_AFTER_SYNC && log_message "Remoção local desabilitada (REMOVE_AFTER_SYNC=false)."
    fi
    log_message "Finalizado com sucesso."
    exit 0
  else
    log_message "Falha no upload. Nenhum arquivo local será removido."
    exit 1
  fi
}

main "$@"
