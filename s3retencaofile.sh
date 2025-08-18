#!/bin/bash
# Configurações
LOG_FILE="/var/log/s3_upload_retencao.log"
LOG_DIR="/mnt/GLFN/datalog"
S3_BUCKET="" # Configure aqui
RETENTION_DAYS=7

# Limpa o arquivo de log
: >"$LOG_FILE"

# Lista dos arquivos enviados com sucesso
declare -a ARQUIVOS_ENVIADOS_OK=()

# Função de log
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Função de sincronização
sync_to_s3() {
    log_message "==== INICIANDO SYNC S3 ===="

    # Criar diretório temporário para organizar arquivos
    local temp_dir="/tmp/s3_sync_$$"
    mkdir -p "$temp_dir"

    # Padrões de arquivos para processar
    local patterns=("tmls2077.log" "tmlauditstore.log" "tmlprocessorerror*.log")
    log_message "Selecionando arquivos elegíveis para diretório temporário..."

    # Encontrar arquivos que atendem aos critérios por padrão
    for pattern in "${patterns[@]}"; do
        log_message "Procurando por padrão: $pattern"
        find "$LOG_DIR" -name "$pattern" -type f | while read -r arquivo; do
            if [ -f "$arquivo" ]; then
                local basename_arquivo=$(basename "$arquivo")

                # Pular arquivos protegidos
                if [[ "$basename_arquivo" =~ "tmlserver.log" ]] || [[ "$basename_arquivo" =~ "tmls.log" ]]; then
                    log_message "Arquivo PROTEGIDO, pulando: $basename_arquivo"
                    continue
                fi

                log_message "Preparando para sync: $basename_arquivo"

                # Copiar para temp (mantém original)
                cp "$arquivo" "$temp_dir/"
                if [ -f "$temp_dir/$basename_arquivo" ]; then
                    total_files=$(ls "$temp_dir" | wc -l)
                    log_message "SUCESSO - Preparado: $basename_arquivo"
                else
                    log_message "ERRO ao preparar: $basename_arquivo"
                fi
            fi
        done
    done

    log_message "==== EXECUTANDO AWS S3 SYNC ===="
    log_message "Diretório origem: $temp_dir"
    log_message "Destino S3: $S3_BUCKET"
    log_message "Executar o 'sync'"

    local sync_output=$(mktemp)
    /usr/local/bin/aws s3 sync "$temp_dir" "s3://$S3_BUCKET" --delete --exact-timestamps 2>&1 | tee "$sync_output" | tee -a "$LOG_FILE"
    log_message "AWS S3 Sync executado com sucesso!"

    # Analisar output do sync para identificar sucessos
    while IFS= read -r linha; do
        if [[ "$linha" =~ upload: ]]; then
            # Extrair nome do arquivo da linha de upload
            local arquivo_sync=$(echo "$linha" | grep -oP '(?<=upload: ).*' | grep -oP '[^/]*\.logs')
            if [ -n "$arquivo_sync" ]; then
                # Encontrar arquivo original correspondente
                local arquivo_original=$(find $LOG_DIR -name "$arquivo_sync" -type f | head -1)
                if [ -n "$arquivo_original" ]; then
                    ARQUIVOS_ENVIADOS_OK+=("$arquivo_original")
                    log_message "SUCESSO -> Adicionado à lista: $arquivo_sync"
                fi
            fi
        fi
    done < "$sync_output"
    rm -f "$sync_output"

    else
        log_message "ERRO no sync S3!"
        rm -rf "$temp_dir"
        return 1
    fi

    # Limpar diretório temporário
    rm -rf "$temp_dir"

    log_message "==== RESUMO DO SYNC ===="
    log_message "Total de arquivos processados: $total_files"
    log_message "Sucessos identificados: ${#ARQUIVOS_ENVIADOS_OK[@]}"
    log_message "Lista dos arquivos sincronizados:"
    if [ ${#ARQUIVOS_ENVIADOS_OK[@]} -eq 0 ]; then
        log_message "⚠️  AVISO: NENHUM arquivo foi sincronizado!"
    else
        for arquivo in "${ARQUIVOS_ENVIADOS_OK[@]}"; do
            log_message "SUCESSO: $(basename "$arquivo")"
        done
    fi
    return 0
}

# Função de remoção – SÓ REMOVE OS DA LISTA
remover_apenas_enviados() {
    log_message "====== REMOÇÃO SEGURA - SÓ OS SINCRONIZADOS ======"
    if [ ${#ARQUIVOS_ENVIADOS_OK[@]} -eq 0 ]; then
        log_message "⚠️  SEGURANÇA: Nenhum arquivo para remover (lista vazia)"
        return 0
    fi

    local removed_count=0
    log_message "Verificando ${#ARQUIVOS_ENVIADOS_OK[@]} arquivos da lista de sincronizados..."
    # Loop na lista de arquivos sincronizados com sucesso
    for arquivo in "${ARQUIVOS_ENVIADOS_OK[@]}"; do
        if [ ! -f "$arquivo" ]; then
            log_message "AVISO: Arquivo já foi removido! $(basename "$arquivo")"
            continue
        fi

        log_message "REMOVENDO (foi sincronizado): $(basename "$arquivo")"
        if rm -f "$arquivo"; then
            removed_count=$((removed_count + 1))
            log_message "REMOVIDO: $(basename "$arquivo")"
        else
            log_message "ERRO ao remover: $(basename "$arquivo")"
        fi
    done

    log_message "Total de arquivos REMOVIDOS: $removed_count"
    log_message "====== Remoção segura concluída! ======"
}

# Função principal
main() {
    log_message "Script de retenção com S3 SYNC iniciando..."
    log_message "Diretório: $LOG_DIR"
    log_message "Bucket S3: $S3_BUCKET"
    log_message "Retenção: $RETENTION_DAYS dias"

    # Verificações básicas
    if [ ! -d "$LOG_DIR" ]; then
        log_message "ERRO: Diretório não encontrado: $LOG_DIR"
        exit 1
    fi

    if [ "$S3_BUCKET" = "seu-bucket" ] || [ -z "$S3_BUCKET" ]; then
        log_message "ERRO: Configure o bucket S3 na variável S3_BUCKET"
        exit 1
    fi

    # 1. PRIMEIRO: Sync para S3
    log_message "FASE 1: Sincronização com S3..."
    if sync_to_s3; then
        log_message "Sync concluído com sucessos na lista"

        # 2. SEGUNDO: Remove APENAS os da lista
        log_message "FASE 2: Remoção segura (só os sincronizados)..."
        remover_apenas_enviados
        log_message "Script finalizado COM SUCESSO!"
        exit 0
    else
        log_message "⚠️  AVISO: NENHUMA sincronização bem-sucedida – NADA será removido!"
        log_message "Todos os arquivos locais foram PRESERVADOS por segurança"
    fi
}

# Executar
main "$@"
