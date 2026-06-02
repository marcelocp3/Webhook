import json
from typing import Any

import requests
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI()

# Esta lista serve como banco de dados fictício, para efeito deste exercício.
confirmations = []

# Token de segurança compartilhado.
SECRET_TOKEN = 'meu-token-secreto'

# Gateway para cancelamento e confirmação.
gateway_url = 'http://127.0.0.1:5001'


def read_token(req: Request) -> str | None:
    """Lê o token de autenticação do header da requisição."""
    return req.headers.get('X-Webhook-Token')


async def read_payload(req: Request) -> dict | None:
    """Tenta ler o payload JSON da requisição."""
    try:
        data = await req.json()
        return data
    except Exception:
        return None


async def cancel_transaction(tx_id: str) -> None:
    """Função auxiliar para cancelar uma transação via gateway."""
    requests.post(
        f'{gateway_url}/cancelar',
        data=json.dumps({'transaction_id': tx_id}),
        headers={'Content-Type': 'application/json'},
    )


async def confirm_transaction(tx_id: str) -> None:
    """Função auxiliar para confirmar uma transação via gateway."""
    confirmations.append(tx_id)
    requests.post(
        f'{gateway_url}/confirmar',
        data=json.dumps({'transaction_id': tx_id}),
        headers={'Content-Type': 'application/json'},
    )


def is_confirmed(tx_id: str) -> bool:
    """Verifica se a transação já foi confirmada."""
    return tx_id in confirmations


def validate_token(token: str | None) -> tuple[bool, JSONResponse | None]:
    """Valida o token de autenticação do webhook."""
    if token is None or token != SECRET_TOKEN:
        response = JSONResponse(
            {
                'status': 'cancelled',
                'reason': 'invalid token',
            },
            status_code=403,
        )
        return False, response

    return True, None


def validate_payload_exists(data: Any | None) -> tuple[bool, JSONResponse | None]:
    """Valida se o payload existe e é um dicionário."""
    if data is None or not isinstance(data, dict):
        response = JSONResponse(
            {
                'status': 'cancelled',
                'reason': 'invalid payload',
            },
            status_code=400,
        )
        return False, response

    return True, None


def validate_transaction_id_exists(data: dict) -> tuple[bool, JSONResponse | None]:
    """Valida se o campo transaction_id está presente no payload."""
    if 'transaction_id' not in data:
        response = JSONResponse(
            {
                'status': 'cancelled',
                'reason': 'missing field: transaction_id',
            },
            status_code=400,
        )
        return False, response

    return True, None


def validate_remaining_payload_fields_exist(data: dict) -> tuple[bool, JSONResponse | None]:
    """Valida se os campos obrigatórios estão presentes no payload."""
    for key in ['event', 'amount', 'currency', 'timestamp']:
        if key not in data:
            response = JSONResponse(
                {
                    'status': 'cancelled',
                    'reason': f'missing field: {key}',
                },
                status_code=400,
            )
            return False, response

    return True, None


def validate_not_confirmed(tx_id: str) -> tuple[bool, JSONResponse | None]:
    """Valida se a transação já foi confirmada (evita duplicações)."""
    if is_confirmed(tx_id):
        response = JSONResponse(
            {
                'status': 'cancelled',
                'transaction_id': tx_id,
                'reason': 'transaction duplicated',
            },
            status_code=400,
        )
        return False, response

    return True, None


def validate_order(
    tx_id: str, amount: str, currency: str
) -> tuple[bool, JSONResponse | None]:
    """Valida se a transação tem o valor e moeda esperados.
    Este é um teste específico para este exercício, onde esperamos um valor
    de R$ 49,90 em BRL. Em um cenário real, esta validação poderia envolver uma 
    consulta a um banco de dados ou outro serviço.
    """
    if amount != '49.90' or currency != 'BRL':
        response = JSONResponse(
            {
                'status': 'cancelled',
                'transaction_id': tx_id,
                'reason': 'mismatch',
            },
            status_code=400,
        )
        return False, response

    return True, None


@app.post('/webhook')
async def handle_webhook(request: Request):
    # Lê e valida o token de autenticação.
    auth_token = read_token(request)
    is_valid, response = validate_token(auth_token)
    if not is_valid:
        return response

    # Lê o payload e verifica se é um JSON válido.
    data = await read_payload(request)
    is_valid, response = validate_payload_exists(data)
    if not is_valid:
        return response

    # Valida os campos obrigatórios e seus valores.
    assert isinstance(data, dict)  # Para apaziguar o linter.
    is_valid, response = validate_transaction_id_exists(data)
    if not is_valid:
        return response

    tx_id = data.get('transaction_id', False)
    is_valid, response = validate_remaining_payload_fields_exist(data)
    if not is_valid:
        await cancel_transaction(tx_id)
        return response

    # Verifica se a transação já foi confirmada (evita duplicações).
    is_valid, response = validate_not_confirmed(tx_id)
    if not is_valid:
        await cancel_transaction(tx_id)
        return response

    # Teste: verifica se a transação tem o valor e moeda esperados.
    amount = data.get('amount', False)
    currency = data.get('currency', False)
    is_valid, response = validate_order(tx_id, amount, currency)
    if not is_valid:
        await cancel_transaction(tx_id)
        return response

    # Se tudo estiver correto, confirma a transação.
    await confirm_transaction(tx_id)
    return JSONResponse(
        {
            'status': 'confirmed',
            'transaction_id': tx_id,
        },
        status_code=200,
    )


if __name__ == '__main__':
    uvicorn.run(app, host='127.0.0.1', port=5000)
