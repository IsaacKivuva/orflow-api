import os
import json
import uuid
import logging
from datetime import datetime, timezone
from flask import Flask, request, jsonify


class JSONFormatter(logging.Formatter):
    """Format every log record as a single-line JSON object."""
    def format(self, record):
        log_entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level":     record.levelname,
            "service":   "orflow-api",
            "env":       os.getenv("ENV", "unknown"),
            "message":   record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key not in (
                "name", "msg", "args", "levelname", "levelno", "pathname",
                "filename", "module", "exc_info", "exc_text", "stack_info",
                "lineno", "funcName", "created", "msecs", "relativeCreated",
                "thread", "threadName", "processName", "process", "message",
            ):
                log_entry[key] = value
        return json.dumps(log_entry)


handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logging.root.setLevel(logging.INFO)
logging.root.addHandler(handler)
logger = logging.getLogger(__name__)

# App initialisation
app = Flask(__name__)


orders = []

DB_HOST = os.getenv("DB_HOST", "localhost")   # injected by ConfigMap
ENV     = os.getenv("ENV",     "development") # injected by ConfigMap

logger.info("OrFlow API starting", extra={"db_host": DB_HOST, "env": ENV})

# Routes

@app.route("/health", methods=["GET"])
def health():
    """
    Liveness and readiness probe endpoint.
    Kubernetes probes hit this on every check interval.
    The Jenkins smoke test hits this before opening the approval gate.
    Always returns 200 as long as the process is running.
    """
    logger.info("Health check passed", extra={"status_code": 200})
    return jsonify({
        "status":  "ok",
        "env":     ENV,
        "db_host": DB_HOST,
    }), 200


@app.route("/orders", methods=["POST"])
def create_order():
    """
    Accept a new order.
    Expected JSON body: { "item": "<name>", "quantity": <int>, "amount": <float> }
    Returns the created order with a generated order_id and timestamp.

    On success, logs a structured event that the serverless receipt chain
    (kk-receiver) will consume.
    """
    data = request.get_json(silent=True)

    # --- input validation ---
    if not data:
        logger.error("Order rejected: empty body", extra={"status_code": 400})
        return jsonify({"error": "Request body must be valid JSON"}), 400

    missing = [f for f in ("item", "quantity", "amount") if f not in data]
    if missing:
        logger.error(
            "Order rejected: missing fields",
            extra={"missing_fields": missing, "status_code": 400}
        )
        return jsonify({"error": f"Missing required fields: {missing}"}), 400

    # --- build order record ---
    order = {
        "order_id":  str(uuid.uuid4()),
        "item":      data["item"],
        "quantity":  data["quantity"],
        "amount":    data["amount"],
        "env":       ENV,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    orders.append(order)

    # Structured success log — kk-receiver listens for event_type=order_created
    logger.info(
        "Order created",
        extra={
            "event_type": "order_created",
            "order_id":   order["order_id"],
            "amount":     order["amount"],
            "status_code": 201,
        }
    )
    return jsonify(order), 201


@app.route("/orders", methods=["GET"])
def list_orders():
    """
    Return all orders currently in the in-memory store.
    """
    logger.info("Orders listed", extra={"count": len(orders), "status_code": 200})
    return jsonify({"orders": orders, "count": len(orders)}), 200


# Error handlers — ensures all errors emit structured JSON logs

@app.errorhandler(404)
def not_found(e):
    logger.error("Route not found", extra={"status_code": 404})
    return jsonify({"error": "Not found"}), 404


@app.errorhandler(405)
def method_not_allowed(e):
    logger.error("Method not allowed", extra={"status_code": 405})
    return jsonify({"error": "Method not allowed"}), 405


@app.errorhandler(500)
def internal_error(e):
    logger.error("Internal server error", extra={"status_code": 500})
    return jsonify({"error": "Internal server error"}), 500



if __name__ == "__main__": 
    # Debug mode is OFF by default.
    # The container sets ENV via ConfigMap; never run debug=True in staging/prod.
    app.run(host="0.0.0.0", port=5000, debug=False)