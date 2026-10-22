# ==========================================
# Observabilidad: SNS, CloudWatch Logs, IAM, dashboard y alarmas
# ==========================================

variable "alarm_email" {
  description = "Email suscripto al topic SNS de alarmas. Se pasa por terraform.tfvars (gitignored)."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Retencion de los log groups de la aplicacion y de metricas EMF"
  type        = number
  default     = 7
}

# ------------------------------------------
# SNS (notificaciones de alarma)
# ------------------------------------------

resource "aws_sns_topic" "alarms" {
  name = "${var.project}-alarms"

  tags = {
    Name = "${var.project}-alarms"
  }
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count = var.alarm_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ------------------------------------------
# CloudWatch Logs
# ------------------------------------------

resource "aws_cloudwatch_log_group" "application" {
  name              = "/aws/${var.project}/application"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project}-application-logs"
  }
}

# El exporter awsemf escribe los documentos EMF como logs; CloudWatch extrae
# las metricas del namespace JournalAPI a partir de ellos.
resource "aws_cloudwatch_log_group" "metrics" {
  name              = "/aws/${var.project}/metrics"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project}-metrics"
  }
}

# ------------------------------------------
# IAM: minimo privilegio para ADOT + Fluent Bit
# ------------------------------------------

data "aws_iam_policy_document" "observability" {
  statement {
    sid       = "XRayWrite"
    effect    = "Allow"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  statement {
    sid       = "CloudWatchMetricsWrite"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["JournalAPI"]
    }
  }

  statement {
    sid       = "LogsCreateGroup"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/${var.project}/*"]
  }

  statement {
    sid    = "LogsWriteStreams"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = [
      "${aws_cloudwatch_log_group.application.arn}:*",
      "${aws_cloudwatch_log_group.metrics.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "observability" {
  name   = "${var.project}-observability-policy"
  role   = aws_iam_role.journal_ssm_role.id
  policy = data.aws_iam_policy_document.observability.json
}

# ------------------------------------------
# Dashboard como codigo
# ------------------------------------------

resource "aws_cloudwatch_dashboard" "journal" {
  dashboard_name = var.project

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Requests por status class"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = "Sum"
          # OTelLib es la dimension que el exporter awsemf agrega con el nombre del
          # meter de OpenTelemetry. CloudWatch exige que el set de dimensiones del
          # widget/alarma coincida exacto, por eso se declara siempre.
          metrics = [
            ["JournalAPI", "journal.http.requests.total", "OTelLib", var.project, "status_class", "2xx", { id = "m2", label = "2xx", stat = "Sum" }],
            ["JournalAPI", "journal.http.requests.total", "OTelLib", var.project, "status_class", "3xx", { id = "m3", label = "3xx", stat = "Sum" }],
            ["JournalAPI", "journal.http.requests.total", "OTelLib", var.project, "status_class", "4xx", { id = "m4", label = "4xx", stat = "Sum" }],
            ["JournalAPI", "journal.http.requests.total", "OTelLib", var.project, "status_class", "5xx", { id = "m5", label = "5xx", stat = "Sum" }],
          ]
          yAxis = {
            left = {
              min   = 0
              label = "requests"
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Error rate 5xx (%)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["JournalAPI", "journal.http.requests.total", "OTelLib", var.project, "status_class", "2xx", { id = "e2", visible = false, stat = "Sum" }],
            ["JournalAPI", "journal.http.requests.total", "OTelLib", var.project, "status_class", "3xx", { id = "e3", visible = false, stat = "Sum" }],
            ["JournalAPI", "journal.http.requests.total", "OTelLib", var.project, "status_class", "4xx", { id = "e4", visible = false, stat = "Sum" }],
            ["JournalAPI", "journal.http.requests.total", "OTelLib", var.project, "status_class", "5xx", { id = "e5", visible = false, stat = "Sum" }],
            [{ expression = "100 * e5 / (e2 + e3 + e4 + e5)", label = "5xx (%)", id = "error_rate" }],
          ]
          yAxis = {
            left = {
              min   = 0
              max   = 100
              label = "%"
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Latencia HTTP p50 / p95 (ms, rolling 500 requests)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Average"
          metrics = [
            ["JournalAPI", "journal.http.latency.p50", "OTelLib", var.project, { id = "p50", label = "p50", stat = "Average" }],
            ["JournalAPI", "journal.http.latency.p95", "OTelLib", var.project, { id = "p95", label = "p95", stat = "Average" }],
          ]
          yAxis = {
            left = {
              min   = 0
              label = "ms"
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Entradas creadas"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["JournalAPI", "journal.entries.created", "OTelLib", var.project, { id = "entries", label = "entries", stat = "Sum" }],
          ]
          yAxis = {
            left = {
              min   = 0
              label = "count"
            }
          }
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          title  = "Errores recientes (Logs Insights)"
          region = var.aws_region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.application.name}' | fields @timestamp, @message | filter @message like / 5[0-9][0-9] / or @message like /ERROR/ | sort @timestamp desc | limit 20"
        }
      },
    ]
  })
}

# ------------------------------------------
# Queries guardadas (Logs Insights)
# ------------------------------------------

resource "aws_cloudwatch_query_definition" "errors" {
  name = "${var.project}/errores-5xx"

  log_group_names = [aws_cloudwatch_log_group.application.name]

  query_string = <<-QUERY
    fields @timestamp, @message
    | filter @message like /ERROR/ or @message like / 5[0-9][0-9] /
    | sort @timestamp desc
    | limit 50
  QUERY
}

resource "aws_cloudwatch_query_definition" "requests_by_route" {
  name = "${var.project}/requests-por-ruta"

  log_group_names = [aws_cloudwatch_log_group.application.name]

  query_string = <<-QUERY
    fields @timestamp, @message
    | parse @message /(?<method>GET|POST|PATCH|DELETE) (?<path>\/[A-Za-z0-9\/{}_-]*) [^ ]* (?<status>[1-5][0-9][0-9]) /
    | filter ispresent(status)
    | stats count() as requests by path, status
    | sort requests desc
  QUERY
}

# ------------------------------------------
# Alarmas
# ------------------------------------------

resource "aws_cloudwatch_metric_alarm" "http_5xx" {
  alarm_name          = "${var.project}-http-5xx"
  alarm_description   = "Mas de 5 respuestas 5xx en 1 minuto"
  namespace           = "JournalAPI"
  metric_name         = "journal.http.requests.total"
  dimensions          = { OTelLib = var.project, status_class = "5xx" }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${var.project}-latency-p95"
  alarm_description   = "p95 de latencia HTTP por encima de 2000 ms durante 3 minutos"
  namespace           = "JournalAPI"
  metric_name         = "journal.http.latency.p95"
  dimensions          = { OTelLib = var.project }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 2000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ------------------------------------------
# Outputs
# ------------------------------------------

output "cloudwatch_dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.journal.dashboard_name}"
}

output "alarm_http_5xx_arn" {
  value = aws_cloudwatch_metric_alarm.http_5xx.arn
}

output "alarm_latency_p95_arn" {
  value = aws_cloudwatch_metric_alarm.latency_p95.arn
}

output "sns_alarms_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "application_log_group" {
  value = aws_cloudwatch_log_group.application.name
}

output "metrics_log_group" {
  value = aws_cloudwatch_log_group.metrics.name
}
