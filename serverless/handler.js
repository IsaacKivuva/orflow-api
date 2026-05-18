"use strict";

const fs   = require("fs");
const path = require("path");
const http = require("http");

// Structured logger
// Every log line is a single JSON object — consistent with main.py's format
const log = (level, functionName, message, extra = {}) => {
  const entry = {
    timestamp:     new Date().toISOString(),
    level,
    service:       "orflow-receipt-chain",
    function:      functionName,
    stage:         process.env.STAGE || "unknown",
    message,
    ...extra,
  };
  console.log(JSON.stringify(entry));
};

// HTTP helper — forwards events to the next function in the chain
// Used by receiver → processor and processor → notifier
const forwardToNext = (path, body) => {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const options = {
      hostname: "localhost",
      port:     3000,
      path:     `${path}`,
      method:   "POST",
      headers: {
        "Content-Type":   "application/json",
        "Content-Length": Buffer.byteLength(payload),
      },
    };

    const req = http.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        try {
          resolve({ statusCode: res.statusCode, body: JSON.parse(data) });
        } catch {
          resolve({ statusCode: res.statusCode, body: data });
        }
      });
    });

    req.on("error", reject);
    req.write(payload);
    req.end();
  });
};

module.exports.receiver = async (event) => {
  const fnName = "kk-receiver";

  log("INFO", fnName, "Event received");

  //Parse body 
  let body;
  try {
    body = typeof event.body === "string" ? JSON.parse(event.body) : event.body;
  } catch (err) {
    log("ERROR", fnName, "Failed to parse event body", { error: err.message });
    return {
      statusCode: 400,
      body: JSON.stringify({ success: false, error: "Invalid JSON body" }),
    };
  }

  //Validate required fields 
  const required = ["order_id", "item", "quantity", "amount"];
  const missing  = required.filter((f) => !(f in body));

  if (missing.length > 0) {
    log("ERROR", fnName, "Validation failed — missing fields", {
      correlation_id: body.order_id || "unknown",
      missing_fields: missing,
    });
    return {
      statusCode: 400,
      body: JSON.stringify({
        success: false,
        error:   `Missing required fields: ${missing.join(", ")}`,
      }),
    };
  }

  log("INFO", fnName, "Validation passed — forwarding to processor", {
    correlation_id: body.order_id,
    item:           body.item,
    amount:         body.amount,
  });

  //Enrich with chain metadata 
  const enriched = {
    ...body,
    chain_started_at: new Date().toISOString(),
    received_by:      fnName,
  };

  // Forward to kk-processor
  try {
    const result = await forwardToNext("/process", enriched);
    log("INFO", fnName, "Forwarded to processor", {
      correlation_id: body.order_id,
      processor_status: result.statusCode,
    });

    return {
      statusCode: 200,
      body: JSON.stringify({
        success: true,
        data:    result.body,
        message: "Event received and forwarded to processor",
      }),
    };
  } catch (err) {
    log("ERROR", fnName, "Failed to forward to processor", {
      correlation_id: body.order_id,
      error:          err.message,
    });
    return {
      statusCode: 500,
      body: JSON.stringify({ success: false, error: "Failed to forward event" }),
    };
  }
};

module.exports.processor = async (event) => {
  const fnName = "kk-processor";

  log("INFO", fnName, "Processing receipt");

  //Parse body
  let body;
  try {
    body = typeof event.body === "string" ? JSON.parse(event.body) : event.body;
  } catch (err) {
    log("ERROR", fnName, "Failed to parse event body", { error: err.message });
    return {
      statusCode: 400,
      body: JSON.stringify({ success: false, error: "Invalid JSON body" }),
    };
  }

  const correlationId = body.order_id || "unknown";
  const taxRate       = parseFloat(process.env.TAX_RATE || "0.16");
  const amount        = parseFloat(body.amount || 0);
  const taxAmount     = parseFloat((amount * taxRate).toFixed(2));
  const totalAmount   = parseFloat((amount + taxAmount).toFixed(2));

  // Generate a receipt ID from order_id + timestamp for traceability
  const receiptId = `RCP-${correlationId.slice(0, 8).toUpperCase()}-${Date.now()}`;

  const receipt = {
    ...body,
    receipt_id:   receiptId,
    tax_rate:     taxRate,
    tax_amount:   taxAmount,
    total_amount: totalAmount,
    processed_at: new Date().toISOString(),
    processed_by: fnName,
  };

  log("INFO", fnName, "Receipt enriched", {
    correlation_id: correlationId,
    receipt_id:     receiptId,
    amount,
    tax_amount:     taxAmount,
    total_amount:   totalAmount,
  });

  //Forward to kk-notifier
  try {
    const result = await forwardToNext("/notify", receipt);
    log("INFO", fnName, "Forwarded to notifier", {
      correlation_id: correlationId,
      receipt_id:     receiptId,
      notifier_status: result.statusCode,
    });

    return {
      statusCode: 200,
      body: JSON.stringify({
        success: true,
        data:    result.body,
        message: "Receipt processed and forwarded to notifier",
      }),
    };
  } catch (err) {
    log("ERROR", fnName, "Failed to forward to notifier", {
      correlation_id: correlationId,
      receipt_id:     receiptId,
      error:          err.message,
    });
    return {
      statusCode: 500,
      body: JSON.stringify({ success: false, error: "Failed to forward receipt" }),
    };
  }
};

module.exports.notifier = async (event) => {
  const fnName    = "kk-notifier";
  const outputFile = process.env.OUTPUT_FILE || "receipts-staging.log";

  log("INFO", fnName, "Writing receipt to output bucket");

  let body;
  try {
    body = typeof event.body === "string" ? JSON.parse(event.body) : event.body;
  } catch (err) {
    log("ERROR", fnName, "Failed to parse event body", { error: err.message });
    return {
      statusCode: 400,
      body: JSON.stringify({ success: false, error: "Invalid JSON body" }),
    };
  }

  const correlationId = body.order_id  || "unknown";
  const receiptId     = body.receipt_id || "unknown";

  const finalReceipt = {
    ...body,
    notified_at: new Date().toISOString(),
    written_by:  fnName,
    destination: outputFile,
  };

  try {
    const outputPath = path.join(__dirname, outputFile);
    fs.appendFileSync(
      outputPath,
      JSON.stringify(finalReceipt) + "\n",
      "utf8"
    );

    log("INFO", fnName, "Receipt written to output", {
      correlation_id: correlationId,
      receipt_id:     receiptId,
      destination:    outputFile,
      total_amount:   body.total_amount,
    });

    return {
      statusCode: 200,
      body: JSON.stringify({
        success:    true,
        receipt_id: receiptId,
        message:    `Receipt written to ${outputFile}`,
      }),
    };
  } catch (err) {
    log("ERROR", fnName, "Failed to write receipt", {
      correlation_id: correlationId,
      receipt_id:     receiptId,
      error:          err.message,
    });
    return {
      statusCode: 500,
      body: JSON.stringify({ success: false, error: "Failed to write receipt" }),
    };
  }
};