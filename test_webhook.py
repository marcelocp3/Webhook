"""Simulando o envio de um webhook

Este script é um teste completo para validar o comportamento de um webhook que processa eventos
de pagamento. O script se comporta como um processador de pagamentos que envia notificações para
um endpoint de webhook, e também inclui um servidor local para receber as confirmações e
cancelamentos gerados pelo webhook.

Ele inclui:

- Um servidor local usando FastAPI para receber confirmações e cancelamentos de transações.
- Vários testes que simulam diferentes cenários de envio de webhook, como:
    - fluxo correto,
    - transação duplicada,
    - amount incorreto,
    - token inválido,
    - payload vazio e
    - campos ausentes.
"""

import asyncio  # Para controle assíncrono
import json  # Para manipular JSON
import sys  # Para capturar argumentos de linha de comando
from copy import deepcopy  # Para criar cópias de dicionários
from threading import Thread  # Para rodar o servidor em paralelo ao teste

import requests  # Para fazer requisições HTTP
import uvicorn  # Para rodar o servidor FastAPI
from fastapi import FastAPI, Request  # Web framework para criar os endpoints locais

# Criação da aplicação FastAPI
app = FastAPI()

# Variáveis para armazenar confirmações e cancelamentos
confirmations = []
cancellations = []


# Endpoint para receber confirmação de transações
@app.post('/confirmar')
async def confirmar(req: Request):
    body = await req.json()
    print('✅ Confirmação recebida:', body)
    confirmations.append(body['transaction_id'])  # Registra a transação confirmada
    return {'status': 'ok'}


# Endpoint para receber cancelamento de transações
@app.post('/cancelar')
async def cancelar(req: Request):
    body = await req.json()
    print('❌ Cancelamento recebido:', body)
    cancellations.append(body['transaction_id'])  # Registra a transação cancelada
    return {'status': 'ok'}


# Função para rodar o servidor FastAPI numa thread separada
def run_server():
    uvicorn.run(app, host='127.0.0.1', port=5001, log_level='error')


# Carrega argumentos de linha de comando ou usa valores padrão
def load_args():
    event = sys.argv[1] if len(sys.argv) > 1 else 'payment_success'
    transaction_id = sys.argv[2] if len(sys.argv) > 2 else 'abc123'
    amount = sys.argv[3] if len(sys.argv) > 3 else '49.90'
    currency = sys.argv[4] if len(sys.argv) > 4 else 'BRL'
    timestamp = sys.argv[5] if len(sys.argv) > 5 else '2023-10-01T12:00:00Z'
    token = sys.argv[6] if len(sys.argv) > 6 else 'meu-token-secreto'

    url = 'http://localhost:5000/webhook'  # URL do webhook a ser testado

    headers = {
        'Content-Type': 'application/json',
        'X-Webhook-Token': token,  # Token de segurança
    }

    data = {
        'event': event,
        'transaction_id': transaction_id,
        'amount': amount,
        'currency': currency,
        'timestamp': timestamp,
    }

    return url, headers, data


def print_test_results(test_index, test_title, test_status):
    msg = 'ok' if test_status else 'failed'
    print(f'{test_index}. Webhook test "{test_title}": {msg}')


# Função principal que executa os testes contra o webhook
async def test_webhook(url, headers, data):

    # Teste: token inválido
    async def test_invalid_token() -> bool:
        test_headers = deepcopy(headers)
        test_headers['X-Webhook-Token'] = 'invalid-token'
        test_data = deepcopy(data)
        test_data['transaction_id'] = 'invalid-token-test'
        response = requests.post(url, headers=test_headers, data=json.dumps(test_data))
        return response.status_code != 200

    # Teste: payload vazio
    async def test_empty_payload() -> bool:
        response = requests.post(url, headers=headers, data=json.dumps({}))
        return response.status_code != 200

    # Teste: campos ausentes (sem timestamp)
    async def test_missing_fields() -> bool:
        test_data = deepcopy(data)
        test_data['transaction_id'] = 'missing-fields'  # Altera ID para evitar conflito
        del test_data['timestamp']  # Remove o campo obrigatório 'timestamp'
        response = requests.post(url, headers=headers, data=json.dumps(test_data))
        await asyncio.sleep(1)
        return response.status_code != 200 and test_data['transaction_id'] in cancellations

    # Teste: fluxo correto
    async def test_correct_flow() -> bool:
        response = requests.post(url, headers=headers, data=json.dumps(data))
        await asyncio.sleep(1)  # Aguarda o webhook chamar /confirmar
        return response.status_code == 200 and data['transaction_id'] in confirmations

    # Teste: transação duplicada (deve falhar se o webhook previne duplicações)
    async def test_duplicate_transaction() -> bool:
        response = requests.post(url, headers=headers, data=json.dumps(data))
        await asyncio.sleep(1)  # Aguarda o webhook chamar /cancelar
        return response.status_code != 200 and data['transaction_id'] in cancellations

    # Teste: amount incorreto
    async def test_incorrect_amount() -> bool:
        test_data = deepcopy(data)
        test_data['transaction_id'] = 'incorrect-amount'  # Altera ID para evitar conflito
        test_data['amount'] = '0.00'
        response = requests.post(url, headers=headers, data=json.dumps(test_data))
        await asyncio.sleep(1)
        return response.status_code != 200 and test_data['transaction_id'] in cancellations

    tests = [
        ('Token Inválido', test_invalid_token),
        ('Payload Vazio', test_empty_payload),
        ('Campos Ausentes', test_missing_fields),
        ('Fluxo Correto', test_correct_flow),
        ('Transação Duplicada', test_duplicate_transaction),
        ('Amount Incorreto', test_incorrect_amount),
    ]

    num_successful_tests = 0

    for index, (title, test_func) in enumerate(tests, start=1):
        status = await test_func()
        if status:
            num_successful_tests += 1
        print_test_results(index, title, status)

    return num_successful_tests


# Bloco principal que inicia o servidor local e executa os testes
if __name__ == '__main__':
    # Roda o servidor local de /confirmar e /cancelar em background
    server_thread = Thread(target=run_server, daemon=True)
    server_thread.start()

    # Aguarda o servidor estar pronto
    asyncio.run(asyncio.sleep(1))

    # Carrega argumentos e executa os testes
    url, headers, data = load_args()
    total = asyncio.run(test_webhook(url, headers, data))

    # Exibe resultado final
    print(f'{total}/6 tests completed.')
    print('Confirmações recebidas:', confirmations)
    print('Cancelamentos recebidos:', cancellations)
