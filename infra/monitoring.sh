#!/usr/bin/env bash
# Flujo 3 y monitoreo: configura métricas de CloudWatch, Metric Filters, alarmas y dashboard.
#
#   infra/monitoring.sh up       crea o actualiza metric filters, alarmas y dashboard
#   infra/monitoring.sh status   muestra el estado de las métricas, alarmas y dashboard
#   infra/monitoring.sh down     elimina el dashboard, las alarmas y los metric filters
#
# Variables opcionales:
#   API_FUNCTION_NAME              Nombre de la Lambda de la API (pinwatch-api por defecto)
#   IMAGE_PROCESSOR_FUNCTION_NAME  Nombre de la Lambda de imágenes (pinwatch-image-processor por defecto)
#   API_LOG_GROUP                  Log group de la API (/aws/lambda/pinwatch-api por defecto)
#   IMAGE_PROCESSOR_LOG_GROUP      Log group de imágenes (/aws/lambda/pinwatch-image-processor por defecto)
#   ORIGINALS_BUCKET               Bucket S3 de originales (pinwatch-originals-<account> por defecto)
#   DASHBOARD_NAME                 Nombre del dashboard (pinwatch-monitoring por defecto)
#   SNS_TOPIC_NAME                 Tópico SNS para notificaciones de alarma (pinwatch-events por defecto)
#   SNS_TOPIC_ARN                  ARN explícito de SNS para alarmas (opcional)
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$INFRA_DIR")"
source "$INFRA_DIR/lib.sh"

API_FUNCTION_NAME="${API_FUNCTION_NAME:-pinwatch-api}"
IMAGE_PROCESSOR_FUNCTION_NAME="${IMAGE_PROCESSOR_FUNCTION_NAME:-pinwatch-image-processor}"
API_LOG_GROUP="${API_LOG_GROUP:-/aws/lambda/$API_FUNCTION_NAME}"
IMAGE_PROCESSOR_LOG_GROUP="${IMAGE_PROCESSOR_LOG_GROUP:-/aws/lambda/$IMAGE_PROCESSOR_FUNCTION_NAME}"
DASHBOARD_NAME="${DASHBOARD_NAME:-pinwatch-monitoring}"
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-pinwatch-events}"
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-}"

# Nombres de Metric Filters
FILTER_API_ERRORS="pinwatch-api-errors-filter"
FILTER_FLUJO3_ACTIVITY="pinwatch-flujo3-activity-filter"
FILTER_IMAGES_PROCESSED="pinwatch-images-processed-filter"

# Namespaces y nombres de métricas custom
METRIC_NS_API="PinWatch/API"
METRIC_NAME_API_ERRORS="ApiErrors"

METRIC_NS_FLUJO3="PinWatch/Flujo3"
METRIC_NAME_FLUJO3_ACTIVITY="Flujo3Activity"

METRIC_NS_IMG="PinWatch/ImageProcessor"
METRIC_NAME_IMAGES_PROCESSED="ImagesProcessed"

# Nombres de Alarmas
ALARM_API_ERRORS="pinwatch-api-errors-alarm"
ALARM_API_LATENCY="pinwatch-api-high-latency-alarm"

set_names() {
  ORIGINALS_BUCKET="${ORIGINALS_BUCKET:-pinwatch-originals-$ACCOUNT_ID}"
  PROCESSED_BUCKET="${PROCESSED_BUCKET:-pinwatch-processed-$ACCOUNT_ID}"
}

find_topic_arn() {
  aws sns list-topics \
    --query "Topics[?ends_with(TopicArn, ':$SNS_TOPIC_NAME')].TopicArn" \
    --output text 2>/dev/null | grep -v '^None$' || true
}

ensure_log_group() {
  local lg="$1"
  if ! aws logs describe-log-groups --log-group-name-prefix "$lg" \
    --query "logGroups[?logGroupName=='$lg'].logGroupName" --output text 2>/dev/null | grep -q "$lg"; then
    log "Creando Log Group $lg..."
    aws logs create-log-group --log-group-name "$lg" 2>/dev/null || true
    aws logs put-retention-policy --log-group-name "$lg" --retention-in-days 7 2>/dev/null || true
  fi
}

build_dashboard_body() {
  python3 -c '
import json, sys

region = sys.argv[1]
account_id = sys.argv[2]
api_fn = sys.argv[3]
orig_bucket = sys.argv[4]
alarm_errors = sys.argv[5]
alarm_latency = sys.argv[6]
ns_api = sys.argv[7]
metric_errors = sys.argv[8]
ns_flujo3 = sys.argv[9]
metric_flujo3 = sys.argv[10]
ns_img = sys.argv[11]
metric_img = sys.argv[12]

alarm_errors_arn = f"arn:aws:cloudwatch:{region}:{account_id}:alarm:{alarm_errors}"
alarm_latency_arn = f"arn:aws:cloudwatch:{region}:{account_id}:alarm:{alarm_latency}"

dashboard = {
    "widgets": [
        {
            "type": "alarm",
            "x": 0,
            "y": 0,
            "width": 24,
            "height": 3,
            "properties": {
                "title": "Estado en Tiempo Real de Alarmas Críticas",
                "alarms": [alarm_errors_arn, alarm_latency_arn]
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 3,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    ["AWS/Lambda", "Duration", "FunctionName", api_fn, {"stat": "Average", "label": "Promedio Latencia (ms)", "color": "#1f77b4"}],
                    ["...", {"stat": "p95", "label": "p95 Latencia (ms)", "color": "#aec7e8"}]
                ],
                "period": 300,
                "region": region,
                "title": "Métrica 1: Latencia API Lambda (Duration)",
                "view": "timeSeries",
                "stacked": False,
                "yAxis": {"left": {"label": "ms", "min": 0}}
            }
        },
        {
            "type": "metric",
            "x": 12,
            "y": 3,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ns_api, metric_errors, {"stat": "Sum", "label": "Errores de Aplicación", "color": "#d62728"}]
                ],
                "period": 300,
                "region": region,
                "title": "Métrica 2: Errores en la API Lambda (Metric Filter)",
                "view": "timeSeries",
                "stacked": False,
                "yAxis": {"left": {"label": "Conteo", "min": 0}}
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 9,
            "width": 8,
            "height": 6,
            "properties": {
                "metrics": [
                    [ns_flujo3, metric_flujo3, {"stat": "Sum", "label": "Creación Tableros / Pines / Likes", "color": "#2ca02c"}]
                ],
                "period": 300,
                "region": region,
                "title": "Métrica 3: Actividad Flujo 3 (Tableros, Pines, Likes)",
                "view": "timeSeries",
                "stacked": False,
                "yAxis": {"left": {"label": "Eventos", "min": 0}}
            }
        },
        {
            "type": "metric",
            "x": 8,
            "y": 9,
            "width": 8,
            "height": 6,
            "properties": {
                "metrics": [
                    [ns_img, metric_img, {"stat": "Sum", "label": "Imágenes Procesadas", "color": "#ff7f0e"}]
                ],
                "period": 300,
                "region": region,
                "title": "Métrica 4: pinwatch-image-processor (Imágenes Procesadas)",
                "view": "timeSeries",
                "stacked": False,
                "yAxis": {"left": {"label": "Conteo", "min": 0}}
            }
        },
        {
            "type": "metric",
            "x": 16,
            "y": 9,
            "width": 8,
            "height": 6,
            "properties": {
                "metrics": [
                    ["AWS/S3", "NumberOfObjects", "StorageType", "AllStorageTypes", "BucketName", orig_bucket, {"stat": "Average", "label": "Cantidad de Objetos"}]
                ],
                "period": 86400,
                "region": region,
                "title": "Métrica 5: S3 Bucket Originals (NumberOfObjects)",
                "view": "singleValue"
            }
        }
    ]
}
print(json.dumps(dashboard))
' "$AWS_REGION" "$ACCOUNT_ID" "$API_FUNCTION_NAME" "$ORIGINALS_BUCKET" \
  "$ALARM_API_ERRORS" "$ALARM_API_LATENCY" \
  "$METRIC_NS_API" "$METRIC_NAME_API_ERRORS" \
  "$METRIC_NS_FLUJO3" "$METRIC_NAME_FLUJO3_ACTIVITY" \
  "$METRIC_NS_IMG" "$METRIC_NAME_IMAGES_PROCESSED"
}

monitoring_up() {
  set_names

  # 1. Asegurar que los grupos de logs existen para poder registrar metric filters
  log "1/4 Verificando Log Groups de CloudWatch..."
  ensure_log_group "$API_LOG_GROUP"
  ensure_log_group "$IMAGE_PROCESSOR_LOG_GROUP"

  # 2. Configurar los 3 Metric Filters (Métricas 2, 3 y 4)
  log "2/4 Configurando Metric Filters en CloudWatch Logs..."

  # Métrica 2: Errores en la API Lambda
  aws logs put-metric-filter \
    --log-group-name "$API_LOG_GROUP" \
    --filter-name "$FILTER_API_ERRORS" \
    --filter-pattern '?"api_error" ?ERROR ?Exception' \
    --metric-transformations \
      "metricName=$METRIC_NAME_API_ERRORS,metricNamespace=$METRIC_NS_API,metricValue=1,defaultValue=0"
  log "Metric Filter '$FILTER_API_ERRORS' configurado en $API_LOG_GROUP ($METRIC_NS_API/$METRIC_NAME_API_ERRORS)"

  # Métrica 3: Actividad de negocio Flujo 3 (Tableros, pines y likes)
  aws logs put-metric-filter \
    --log-group-name "$API_LOG_GROUP" \
    --filter-name "$FILTER_FLUJO3_ACTIVITY" \
    --filter-pattern '?"board_created" ?"pin_created" ?"like_registered"' \
    --metric-transformations \
      "metricName=$METRIC_NAME_FLUJO3_ACTIVITY,metricNamespace=$METRIC_NS_FLUJO3,metricValue=1,defaultValue=0"
  log "Metric Filter '$FILTER_FLUJO3_ACTIVITY' configurado en $API_LOG_GROUP ($METRIC_NS_FLUJO3/$METRIC_NAME_FLUJO3_ACTIVITY)"

  # Métrica 4: Imágenes procesadas en pinwatch-image-processor
  aws logs put-metric-filter \
    --log-group-name "$IMAGE_PROCESSOR_LOG_GROUP" \
    --filter-name "$FILTER_IMAGES_PROCESSED" \
    --filter-pattern '?"imagen_procesada"' \
    --metric-transformations \
      "metricName=$METRIC_NAME_IMAGES_PROCESSED,metricNamespace=$METRIC_NS_IMG,metricValue=1,defaultValue=0"
  log "Metric Filter '$FILTER_IMAGES_PROCESSED' configurado en $IMAGE_PROCESSOR_LOG_GROUP ($METRIC_NS_IMG/$METRIC_NAME_IMAGES_PROCESSED)"

  # 3. Configurar las 2 Alarmas de CloudWatch
  log "3/4 Configurando Alarmas en CloudWatch..."

  # Resolver tópico SNS opcional
  if [[ -z "$SNS_TOPIC_ARN" ]]; then
    SNS_TOPIC_ARN="$(find_topic_arn)"
  fi

  local alarm_actions=()
  if [[ -n "$SNS_TOPIC_ARN" ]]; then
    alarm_actions=(--alarm-actions "$SNS_TOPIC_ARN")
    log "Notificaciones de alarma configuradas hacia SNS: $SNS_TOPIC_ARN"
  else
    log "SNS_TOPIC_ARN no configurado o no encontrado; las alarmas se crearán sin notificaciones SNS automáticas."
  fi

  # Alarma 1: Errores en la API Lambda
  aws cloudwatch put-metric-alarm \
    --alarm-name "$ALARM_API_ERRORS" \
    --alarm-description "Alarma crítica por errores de aplicación o excepciones en la API Lambda (pinwatch-api)" \
    --metric-name "$METRIC_NAME_API_ERRORS" \
    --namespace "$METRIC_NS_API" \
    --statistic "Sum" \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 1 \
    --comparison-operator "GreaterThanOrEqualToThreshold" \
    --treat-missing-data "notBreaching" \
    ${alarm_actions[@]+"${alarm_actions[@]}"} \
    --tags "Key=Project,Value=$PROJECT_TAG" "Key=Owner,Value=$OWNER_TAG" "Key=Name,Value=$ALARM_API_ERRORS"
  log "Alarma '$ALARM_API_ERRORS' creada/actualizada (Umbral >= 1 error en 5 min)."

  # Alarma 2: Alta latencia en la API Lambda
  aws cloudwatch put-metric-alarm \
    --alarm-name "$ALARM_API_LATENCY" \
    --alarm-description "Alarma por latencia promedio alta (>3000 ms) en la API Lambda (pinwatch-api)" \
    --metric-name "Duration" \
    --namespace "AWS/Lambda" \
    --dimensions "Name=FunctionName,Value=$API_FUNCTION_NAME" \
    --statistic "Average" \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 3000 \
    --comparison-operator "GreaterThanThreshold" \
    --unit "Milliseconds" \
    --treat-missing-data "notBreaching" \
    ${alarm_actions[@]+"${alarm_actions[@]}"} \
    --tags "Key=Project,Value=$PROJECT_TAG" "Key=Owner,Value=$OWNER_TAG" "Key=Name,Value=$ALARM_API_LATENCY"
  log "Alarma '$ALARM_API_LATENCY' creada/actualizada (Umbral > 3000 ms promedio en 5 min)."

  # 4. Configurar Dashboard consolidado
  log "4/4 Creando Dashboard consolidado en CloudWatch: $DASHBOARD_NAME..."
  local dashboard_json
  dashboard_json="$(build_dashboard_body)"

  aws cloudwatch put-dashboard \
    --dashboard-name "$DASHBOARD_NAME" \
    --dashboard-body "$dashboard_json"
  log "Dashboard '$DASHBOARD_NAME' creado/actualizado exitosamente."
  log "Monitoreo de PinWatch listo y operativo."
}

monitoring_status() {
  set_names
  log "Estado del monitoreo de CloudWatch para PinWatch"
  log "Log Group API: $API_LOG_GROUP"
  log "Log Group Image Processor: $IMAGE_PROCESSOR_LOG_GROUP"
  log "Bucket Originals: $ORIGINALS_BUCKET"

  log "--- Metric Filters ---"
  aws logs describe-metric-filters --log-group-name "$API_LOG_GROUP" \
    --query "metricFilters[?filterName=='$FILTER_API_ERRORS' || filterName=='$FILTER_FLUJO3_ACTIVITY'].[filterName, metricTransformations[0].metricName, metricTransformations[0].metricNamespace]" \
    --output table 2>/dev/null || warn "No se pudo consultar metric filters en $API_LOG_GROUP"

  aws logs describe-metric-filters --log-group-name "$IMAGE_PROCESSOR_LOG_GROUP" \
    --query "metricFilters[?filterName=='$FILTER_IMAGES_PROCESSED'].[filterName, metricTransformations[0].metricName, metricTransformations[0].metricNamespace]" \
    --output table 2>/dev/null || warn "No se pudo consultar metric filters en $IMAGE_PROCESSOR_LOG_GROUP"

  log "--- Alarmas CloudWatch ---"
  aws cloudwatch describe-alarms --alarm-names "$ALARM_API_ERRORS" "$ALARM_API_LATENCY" \
    --query "MetricAlarms[].[AlarmName, StateValue, MetricName, Threshold, ComparisonOperator]" \
    --output table 2>/dev/null || warn "No se pudo consultar alarmas"

  log "--- Dashboard CloudWatch ---"
  local d_exists
  d_exists="$(aws cloudwatch list-dashboards --dashboard-name-prefix "$DASHBOARD_NAME" \
    --query "DashboardEntries[?DashboardName=='$DASHBOARD_NAME'].DashboardName" --output text 2>/dev/null || true)"
  if [[ -n "$d_exists" && "$d_exists" != "None" ]]; then
    log "Dashboard '$DASHBOARD_NAME': EXISTE"
  else
    log "Dashboard '$DASHBOARD_NAME': NO EXISTE"
  fi
}

monitoring_down() {
  set_names
  confirm "¿Eliminar dashboard, alarmas y metric filters de CloudWatch para PinWatch?" || die "Cancelado."

  log "1/3 Eliminando Dashboard '$DASHBOARD_NAME'..."
  aws cloudwatch delete-dashboards --dashboard-names "$DASHBOARD_NAME" 2>/dev/null || true

  log "2/3 Eliminando Alarmas '$ALARM_API_ERRORS' y '$ALARM_API_LATENCY'..."
  aws cloudwatch delete-alarms --alarm-names "$ALARM_API_ERRORS" "$ALARM_API_LATENCY" 2>/dev/null || true

  log "3/3 Eliminando Metric Filters..."
  aws logs delete-metric-filter --log-group-name "$API_LOG_GROUP" --filter-name "$FILTER_API_ERRORS" 2>/dev/null || true
  aws logs delete-metric-filter --log-group-name "$API_LOG_GROUP" --filter-name "$FILTER_FLUJO3_ACTIVITY" 2>/dev/null || true
  aws logs delete-metric-filter --log-group-name "$IMAGE_PROCESSOR_LOG_GROUP" --filter-name "$FILTER_IMAGES_PROCESSED" 2>/dev/null || true

  log "Monitoreo eliminado correctamente."
}

if [[ $# -eq 0 ]]; then
  set -- "up"
fi

parse_args "$@"
aws_session
"monitoring_$ACTION"
