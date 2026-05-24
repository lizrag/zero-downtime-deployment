"""
Minimal FastAPI service simulating a payment processor authorization service.
"""

import os
import random
import time
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI(title="Authorization Service", version="1.0.0")

# ── Prometheus metrics ─────────────────────────────────────────────────────────
Instrumentator().instrument(app).expose(app)

# ── Config ─────────────────────────────────────────────────────────────────────
PAYMENT_API_KEY = os.getenv("PAYMENT_API_KEY", "NOT_SET")
DB_PASSWORD     = os.getenv("DB_PASSWORD",     "NOT_SET")
BAD_MODE        = os.getenv("BAD_MODE", "false") == "true"


# ── Models ─────────────────────────────────────────────────────────────────────
class AuthorizeRequest(BaseModel):
    transaction_id: str
    amount: float
    currency: str = "USD"
    card_token: str


class AuthorizeResponse(BaseModel):
    transaction_id: str
    status: str
    message: str
    auth_code: str | None = None


# ── Endpoints ──────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    secrets_loaded = PAYMENT_API_KEY != "NOT_SET" and DB_PASSWORD != "NOT_SET"
    return {
        "status": "healthy",
        "version": os.getenv("APP_VERSION", "v1"),
        "secrets_loaded": secrets_loaded,
        "bad_mode": BAD_MODE,
    }


@app.post("/authorize", response_model=AuthorizeResponse)
def authorize(req: AuthorizeRequest):
    if PAYMENT_API_KEY == "NOT_SET" or DB_PASSWORD == "NOT_SET":
        raise HTTPException(status_code=503, detail="Service misconfigured: secrets missing")

    # ── Bad mode: simulates a broken deployment ────────────────────────────────
    if BAD_MODE:
        time.sleep(random.uniform(2.0, 4.0))  
        if random.random() < 0.40:            
            raise HTTPException(status_code=500, detail="Payment processor unreachable")

    roll = random.random()

    if roll < 0.80:
        return AuthorizeResponse(
            transaction_id=req.transaction_id,
            status="approved",
            message="Transaction approved",
            auth_code=f"AUTH-{random.randint(100000, 999999)}",
        )
    elif roll < 0.95:
        return AuthorizeResponse(
            transaction_id=req.transaction_id,
            status="declined",
            message="Insufficient funds",
        )
    else:
        raise HTTPException(status_code=500, detail="Payment processor unreachable")